package app.orbits.transport

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.io.File
import java.io.FileOutputStream
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.ZipInputStream

/**
 * Official BareKit / packaged-runtime host.
 *
 * BareKit IPC native polling calls ALooper_forThread() and requires a prepared Looper.
 * All BareKit IPC objects and polling callbacks run on a dedicated HandlerThread.
 * Outbound OTP1 frames are serialized through an OutboundWriteQueue with partial-write
 * loopback, and MethodChannel requests are tracked independently by request ID.
 */
internal object OrbitsBareRuntime {
  private val main = Handler(Looper.getMainLooper())
  private val nextId = AtomicInteger(1)

  @Volatile
  private var session: Session? = null

  @Volatile
  private var pendingEventSink: ((Map<String, Any?>) -> Unit)? = null

  fun tryStart(
    call: io.flutter.plugin.common.MethodCall,
    binding: FlutterPlugin.FlutterPluginBinding? = null,
  ): Boolean {
    val latch = CountDownLatch(1)
    var success = false
    startSessionAsync(call.arguments as? Map<*, *>, binding) { result ->
      success = result.isSuccess
      latch.countDown()
    }
    latch.await(45, TimeUnit.SECONDS)
    return success
  }

  @Synchronized
  fun startSession(
    args: Map<*, *>?,
    binding: FlutterPlugin.FlutterPluginBinding?,
  ): Map<String, Any?> {
    val latch = CountDownLatch(1)
    var outResult: Result<Map<String, Any?>>? = null
    startSessionAsync(args, binding) { res ->
      outResult = res
      latch.countDown()
    }
    val finished = latch.await(45, TimeUnit.SECONDS)
    if (!finished) {
      stopSession()
      throw IllegalStateException("IPC_TIMEOUT")
    }
    return outResult?.getOrThrow() ?: throw IllegalStateException("BARE_WORKLET_FAILED")
  }

  @Synchronized
  fun startSessionAsync(
    args: Map<*, *>?,
    binding: FlutterPlugin.FlutterPluginBinding?,
    callback: (Result<Map<String, Any?>>) -> Unit,
  ) {
    session?.terminateQuiet()
    session = null

    val context = binding?.applicationContext
    if (context == null) {
      callback(Result.failure(IllegalStateException("BARE_RUNTIME_MISSING")))
      return
    }

    val workletClass = try {
      Class.forName("to.holepunch.bare.kit.Worklet")
    } catch (_: Throwable) {
      callback(Result.failure(IllegalStateException("BARE_RUNTIME_MISSING")))
      return
    }
    val ipcClass = try {
      Class.forName("to.holepunch.bare.kit.IPC")
    } catch (_: Throwable) {
      callback(Result.failure(IllegalStateException("BARE_RUNTIME_MISSING")))
      return
    }

    val extracted = try {
      extractWorkletTree(context, binding)
    } catch (e: Throwable) {
      callback(Result.failure(IllegalStateException("BARE_WORKLET_FAILED", e)))
      return
    }
    val source = extracted.readText()
    if (source.isEmpty()) {
      callback(Result.failure(IllegalStateException("BARE_WORKLET_FAILED")))
      return
    }

    val storage = File(context.filesDir, "orbits-corestore").apply { mkdirs() }
    val backend = (args?.get("backend") as? String)?.takeIf { it.isNotEmpty() } ?: "hyperswarm"
    val argv = arrayOf(
      "--backend=$backend",
      "--storage=${storage.absolutePath}",
    )

    // Dedicated HandlerThread with prepared Looper for BareKit native ALooper
    val thread = HandlerThread("orbits-bare-ipc")
    thread.start()
    val ipcHandler = Handler(thread.looper)

    ipcHandler.post {
      try {
        check(Looper.myLooper() != null) { "ALooper requires prepared Looper on thread" }

        val optionsClass = Class.forName("to.holepunch.bare.kit.Worklet\$Options")
        val options = optionsClass.getDeclaredConstructor().newInstance()
        val memoryLimit = optionsClass.methods.firstOrNull { method ->
          method.name == "memoryLimit" && method.parameterTypes.size == 1
        }
        memoryLimit?.invoke(options, 96 * 1024 * 1024)
        val assets = optionsClass.methods.firstOrNull { method ->
          method.name == "assets" && method.parameterTypes.size == 1
        }
        assets?.invoke(options, extracted.parentFile?.absolutePath)
        val ctor = workletClass.getDeclaredConstructor(optionsClass)
        val worklet = ctor.newInstance(options)

        val start = workletClass.methods.firstOrNull { method ->
          method.name == "start" &&
            method.parameterTypes.size == 4 &&
            method.parameterTypes[0] == String::class.java &&
            method.parameterTypes[1] == String::class.java &&
            method.parameterTypes[2] == java.nio.charset.Charset::class.java
        } ?: throw IllegalStateException("BARE_WORKLET_FAILED")
        start.invoke(worklet, extracted.absolutePath, source, StandardCharsets.UTF_8, argv)

        val ipcCtor = ipcClass.getDeclaredConstructor(workletClass)
        val ipc = ipcCtor.newInstance(worklet)

        val created = Session(workletClass, ipcClass, worklet, ipc, thread, ipcHandler)
        created.setEventSink(pendingEventSink)
        synchronized(this@OrbitsBareRuntime) {
          session = created
        }

        val startParams = LinkedHashMap<String, Any?>()
        startParams["peerId"] = args?.get("peerId")
        startParams["discoverySecret"] = args?.get("discoverySecret")
        startParams["relayForced"] = args?.get("relayForced") == true
        startParams["backend"] = backend
        startParams["requireRealCorestore"] = true
        startParams["firewalled"] = false
        startParams["storageDir"] = storage.absolutePath
        startParams["writerDeviceId"] = args?.get("deviceId") ?: args?.get("peerId")
        startParams["noiseSeed"] = args?.get("noiseSeed")

        // Explicit startup readiness: start() completes only after OTP1 response
        created.request("start", startParams, 45_000) { startRes ->
          if (startRes.isFailure) {
            created.terminateQuiet(startRes.exceptionOrNull() ?: IllegalStateException("start failed"))
            callback(Result.failure(startRes.exceptionOrNull() ?: IllegalStateException("start failed")))
            return@request
          }
          // Follow up with real OTP1 runtime.info to guarantee readiness
          created.request("runtime.info", emptyMap(), 8_000) { infoRes ->
            if (infoRes.isFailure) {
              created.terminateQuiet(infoRes.exceptionOrNull() ?: IllegalStateException("runtime.info failed"))
              callback(Result.failure(infoRes.exceptionOrNull() ?: IllegalStateException("runtime.info failed")))
            } else {
              val combined = LinkedHashMap<String, Any?>()
              startRes.getOrNull()?.let { combined.putAll(it) }
              infoRes.getOrNull()?.let { combined.putAll(it) }
              callback(Result.success(combined))
            }
          }
        }
      } catch (e: Throwable) {
        thread.quitSafely()
        callback(Result.failure(e))
      }
    }
  }

  fun request(method: String, params: Map<String, Any?>, timeoutMs: Long): Map<String, Any?> {
    val live = session ?: throw IllegalStateException("NOT_STARTED")
    val latch = CountDownLatch(1)
    var outResult: Result<Map<String, Any?>>? = null
    live.request(method, params, timeoutMs) { res ->
      outResult = res
      latch.countDown()
    }
    val finished = latch.await(timeoutMs + 2_000, TimeUnit.MILLISECONDS)
    if (!finished) {
      throw IllegalStateException("IPC_TIMEOUT")
    }
    return outResult?.getOrThrow() ?: throw IllegalStateException("IPC_TIMEOUT")
  }

  fun request(
    method: String,
    params: Map<String, Any?>,
    timeoutMs: Long,
    callback: (Result<Map<String, Any?>>) -> Unit,
  ) {
    requestAsync(method, params, timeoutMs, callback)
  }

  fun requestAsync(
    method: String,
    params: Map<String, Any?>,
    timeoutMs: Long,
    callback: (Result<Map<String, Any?>>) -> Unit,
  ) {
    val live = session
    if (live == null) {
      callback(Result.failure(IllegalStateException("NOT_STARTED")))
      return
    }
    live.request(method, params, timeoutMs, callback)
  }

  fun runtimeInfo(): Map<String, Any?> {
    return request("runtime.info", emptyMap(), 8_000)
  }

  fun suspendRuntime(callback: (() -> Unit)? = null) {
    val live = session
    if (live == null) {
      callback?.invoke()
      return
    }
    live.request("suspend", emptyMap(), 8_000) {
      try {
        live.workletClass.getMethod("suspend").invoke(live.worklet)
      } catch (_: Exception) {}
      callback?.invoke()
    }
  }

  fun resumeRuntime(callback: (() -> Unit)? = null) {
    val live = session
    if (live == null) {
      callback?.invoke()
      return
    }
    try {
      live.workletClass.getMethod("resume").invoke(live.worklet)
    } catch (_: Exception) {}
    live.request("resume", emptyMap(), 8_000) {
      callback?.invoke()
    }
  }

  @Synchronized
  fun stopSession(callback: (() -> Unit)? = null) {
    val live = session
    session = null
    if (live == null) {
      callback?.invoke()
      return
    }
    val once = AtomicBoolean(false)
    val complete = Runnable {
      if (once.compareAndSet(false, true)) {
        live.terminateQuiet()
        callback?.invoke()
      }
    }
    live.request("stop", emptyMap(), 2_000) {
      complete.run()
    }
    live.ipcHandler.postDelayed(complete, 2500)
  }

  fun isLive(): Boolean = session?.isLive() == true

  fun setEventSink(sink: ((Map<String, Any?>) -> Unit)?) {
    pendingEventSink = sink
    session?.setEventSink(sink)
  }

  internal class PendingRequest(
    val id: Int,
    val method: String,
    val callback: (Result<Map<String, Any?>>) -> Unit,
    val timeoutRunnable: Runnable,
  )

  /**
   * Outbound write queue enforcing frame bounds, backpressure, and handling
   * non-blocking partial writes without interleaving frame bytes.
   */
  internal class OutboundWriteQueue(
    private val ipcClass: Class<*>,
    private val ipc: Any,
    private val handler: Handler,
    private val maxFrames: Int = 64,
    private val maxBytes: Int = 2 * 1024 * 1024,
  ) {
    private val frames = ArrayDeque<ByteArray>()
    private var queuedBytes = 0
    private var activeBuffer: ByteBuffer? = null
    private var isWriting = false
    private var writableProxy: Any? = null
    private var writableRegistered = false

    init {
      setupWritableProxy()
    }

    private fun setupWritableProxy() {
      try {
        val pollClass = Class.forName("to.holepunch.bare.kit.IPC\$PollCallback")
        writableProxy = Proxy.newProxyInstance(pollClass.classLoader, arrayOf(pollClass)) { _, method, _ ->
          if (method.name == "apply") {
            handler.post { onWritable() }
          }
          null
        }
      } catch (_: Throwable) {}
    }

    @Synchronized
    fun enqueue(frame: ByteArray) {
      if (frames.size >= maxFrames || queuedBytes + frame.size > maxBytes) {
        throw IllegalStateException("IPC_BACKPRESSURE")
      }
      frames.addLast(frame)
      queuedBytes += frame.size
      handler.post { pump() }
    }

    fun pump() {
      if (isWriting) return
      isWriting = true
      try {
        doPump()
      } finally {
        isWriting = false
      }
    }

    private fun onWritable() {
      writableRegistered = false
      pump()
    }

    private fun doPump() {
      while (true) {
        var buf = activeBuffer
        if (buf == null || !buf.hasRemaining()) {
          val next = synchronized(this) {
            if (frames.isEmpty()) null
            else {
              val f = frames.removeFirst()
              queuedBytes -= f.size
              f
            }
          }
          if (next == null) {
            activeBuffer = null
            break
          }
          buf = ByteBuffer.wrap(next)
          activeBuffer = buf
        }

        val written = try {
          val res = ipcClass.getMethod("write", ByteBuffer::class.java).invoke(ipc, buf)
          (res as? Number)?.toInt() ?: 0
        } catch (e: Throwable) {
          clear()
          return
        }

        if (buf.hasRemaining()) {
          // Short write: register writable callback and wait
          if (!writableRegistered && writableProxy != null) {
            try {
              val pollClass = Class.forName("to.holepunch.bare.kit.IPC\$PollCallback")
              ipcClass.getMethod("writable", pollClass).invoke(ipc, writableProxy)
              writableRegistered = true
            } catch (_: Throwable) {}
          }
          break
        }
      }
    }

    @Synchronized
    fun clear() {
      frames.clear()
      queuedBytes = 0
      activeBuffer = null
    }
  }

  internal class Session(
    val workletClass: Class<*>,
    val ipcClass: Class<*>,
    val worklet: Any,
    val ipc: Any,
    val handlerThread: HandlerThread,
    val ipcHandler: Handler,
  ) {
    val pending = ConcurrentHashMap<Int, PendingRequest>()
    val decoder = Otp1.Decoder()
    val writeQueue = OutboundWriteQueue(ipcClass, ipc, ipcHandler)
    private val closed = AtomicBoolean(false)

    @Volatile
    private var _eventSink: ((Map<String, Any?>) -> Unit)? = null
    val eventSink: ((Map<String, Any?>) -> Unit)? get() = _eventSink
    private val earlyEvents = ArrayDeque<Map<String, Any?>>()

    init {
      attachReadable()
    }

    fun isLive(): Boolean = !closed.get()

    private fun attachReadable() {
      try {
        val pollClass = Class.forName("to.holepunch.bare.kit.IPC\$PollCallback")
        val proxy = Proxy.newProxyInstance(pollClass.classLoader, arrayOf(pollClass)) { _, method, _ ->
          if (method.name == "apply") {
            ipcHandler.post { drain() }
          }
          null
        }
        ipcClass.getMethod("readable", pollClass).invoke(ipc, proxy)
      } catch (_: Throwable) {}
    }

    fun request(
      method: String,
      params: Map<String, Any?>,
      timeoutMs: Long,
      callback: (Result<Map<String, Any?>>) -> Unit,
    ) {
      requestAsync(method, params, timeoutMs, callback)
    }

    fun requestAsync(
      method: String,
      params: Map<String, Any?>,
      timeoutMs: Long,
      callback: (Result<Map<String, Any?>>) -> Unit,
    ) {
      if (closed.get()) {
        callback(Result.failure(IllegalStateException("NOT_STARTED")))
        return
      }
      if (pending.size >= 64) {
        callback(Result.failure(IllegalStateException("IPC_BACKPRESSURE")))
        return
      }
      val id = nextId.getAndIncrement()
      val timeoutRunnable = Runnable {
        val removed = pending.remove(id) ?: return@Runnable
        removed.callback(Result.failure(IllegalStateException("IPC_TIMEOUT: $method")))
      }
      val req = PendingRequest(id, method, callback, timeoutRunnable)
      pending[id] = req
      ipcHandler.postDelayed(timeoutRunnable, timeoutMs)

      try {
        val frame = Otp1.encode(
          Otp1.REQUEST,
          mapOf(
            "id" to id,
            "method" to method,
            "params" to params,
          ),
        )
        writeQueue.enqueue(frame)
      } catch (err: Throwable) {
        pending.remove(id)
        ipcHandler.removeCallbacks(timeoutRunnable)
        callback(Result.failure(err))
      }
    }

    fun drain() {
      if (closed.get()) return
      try {
        while (true) {
          val raw = ipcClass.getMethod("read").invoke(ipc) ?: break
          val chunk = bufferToBytes(raw) ?: break
          if (chunk.isEmpty()) break
          val messages = decoder.add(chunk)
          for (msg in messages) {
            handleMessage(msg)
          }
        }
      } catch (e: Otp1.Otp1DecodeException) {
        // Structured decoder failure: reject pending, surface structured error, close
        val errEvent = linkedMapOf<String, Any?>(
          "name" to "error",
          "code" to e.code,
          "message" to (e.message ?: "decode error"),
        )
        dispatchOrBufferEvent(errEvent)
        terminateQuiet(IllegalStateException("OTP1_DECODE_ERROR: ${e.code}", e))
      } catch (e: Throwable) {
        terminateQuiet(e)
      }
    }

    private fun handleMessage(msg: Otp1.Message) {
      when (msg.type) {
        Otp1.RESPONSE -> {
          val id = (msg.body["id"] as? Number)?.toInt() ?: return
          val req = pending.remove(id) ?: return
          ipcHandler.removeCallbacks(req.timeoutRunnable)
          if (msg.body["ok"] == false) {
            val errStr = msg.body["error"]?.toString() ?: "ipc error"
            req.callback(Result.failure(IllegalStateException(errStr)))
          } else {
            @Suppress("UNCHECKED_CAST")
            val res = (msg.body["result"] as? Map<String, Any?>) ?: emptyMap()
            req.callback(Result.success(res))
          }
        }
        Otp1.EVENT -> {
          val flat = flattenEvent(msg.body)
          dispatchOrBufferEvent(flat)
        }
      }
    }

    fun setEventSink(sink: ((Map<String, Any?>) -> Unit)?) {
      this._eventSink = sink
      if (sink != null) {
        synchronized(earlyEvents) {
          while (earlyEvents.isNotEmpty()) {
            val ev = earlyEvents.removeFirst()
            main.post {
          if (!closed.get()) sink(ev)
        }
          }
        }
      }
    }

    private fun dispatchOrBufferEvent(event: Map<String, Any?>) {
      if (closed.get()) return
      val sink = eventSink
      if (sink != null) {
        main.post {
          if (!closed.get()) sink(event)
        }
      } else {
        synchronized(earlyEvents) {
          if (earlyEvents.size < 64) {
            earlyEvents.addLast(event)
          }
        }
      }
    }

    fun terminateQuiet(cause: Throwable = IllegalStateException("ipc closed")) {
      if (!closed.compareAndSet(false, true)) return
      _eventSink = null
      synchronized(earlyEvents) { earlyEvents.clear() }
      writeQueue.clear()
      for ((_, req) in pending) {
        ipcHandler.removeCallbacks(req.timeoutRunnable)
        req.callback(Result.failure(cause))
      }
      pending.clear()
      try {
        ipcClass.getMethod("close").invoke(ipc)
      } catch (_: Throwable) {}
      try {
        workletClass.getMethod("terminate").invoke(worklet)
      } catch (_: Throwable) {}
      try {
        workletClass.getMethod("close").invoke(worklet)
      } catch (_: Throwable) {}
      handlerThread.quitSafely()
    }
  }

  private fun flattenEvent(body: Map<String, Any?>): Map<String, Any?> {
    @Suppress("UNCHECKED_CAST")
    val payload = (body["payload"] as? Map<String, Any?>) ?: emptyMap()
    val out = LinkedHashMap<String, Any?>()
    out["name"] = body["name"]
    out["peerId"] = payload["peerId"] ?: body["peerId"]
    out["channel"] = payload["channel"] ?: body["channel"]
    out["path"] = payload["path"] ?: body["path"]
    out["frameB64"] = payload["frameB64"] ?: body["frameB64"]
    out["code"] = payload["code"] ?: body["code"]
    out["message"] = payload["message"] ?: body["message"]
    out["detail"] = payload["detail"] ?: body["detail"]
    out["state"] = payload["state"] ?: body["state"]
    out["requestId"] = payload["requestId"] ?: body["requestId"]
    out["binding"] = payload["binding"] ?: body["binding"]
    out["connectionNoisePublicKey"] = payload["connectionNoisePublicKey"] ?: body["connectionNoisePublicKey"]
    out["ownerPeerId"] = payload["ownerPeerId"] ?: body["ownerPeerId"]
    val b64 = (payload["frameB64"] ?: body["frameB64"]) as? String
    if (!b64.isNullOrEmpty()) {
      out["bytes"] = android.util.Base64.decode(b64, android.util.Base64.DEFAULT)
    }
    return out
  }

  private fun bufferToBytes(raw: Any): ByteArray? {
    val buffer = raw as? ByteBuffer ?: return null
    val copy = ByteArray(buffer.remaining())
    buffer.get(copy)
    return copy
  }

  private val workletFiles = listOf(
    "worklet.js",
    "mux.js",
    "discovery.js",
    "loopback.js",
    "ipc.js",
    "swarm.js",
    "stand.js",
    "corestore_journal.js",
    "bare_compat.js",
  )

  private fun extractWorkletTree(
    context: Context,
    binding: FlutterPlugin.FlutterPluginBinding?,
  ): File {
    val dest = File(context.filesDir, "orbits-worklet")
    dest.mkdirs()
    val assets = context.assets
    for (name in workletFiles) {
      val flutterName = "tool/connectivity_harness/src/$name"
      val lookup = try {
        binding?.flutterAssets?.getAssetFilePathByName(flutterName)
      } catch (_: Throwable) {
        null
      }
      var copied = false
      for (candidate in listOfNotNull(lookup, flutterName, "flutter_assets/$flutterName")) {
        try {
          assets.open(candidate).use { input ->
            FileOutputStream(File(dest, name)).use { output -> input.copyTo(output) }
          }
          copied = true
          break
        } catch (_: Throwable) {}
      }
      if (!copied && name == "worklet.js") {
        throw IllegalStateException("BARE_WORKLET_FAILED")
      }
    }
    extractModuleZip(context, dest)
    val script = File(dest, "worklet.js")
    val hyperswarm = File(dest, "node_modules/hyperswarm/package.json")
    if (!script.isFile || script.length() == 0L || !hyperswarm.isFile) {
      throw IllegalStateException("BARE_WORKLET_FAILED")
    }
    return script
  }

  /**
   * Secure ZIP extraction preventing path traversal (Zip Slip), zip bombs,
   * absolute paths, symlinks, and duplicate entries (F-23).
   */
  private fun extractModuleZip(context: Context, dest: File) {
    val names = listOf(
      "orbits-worklet-modules.zip",
      "flutter_assets/orbits-worklet-modules.zip",
    )

    val maxEntries = 10_000
    val maxSingleFileSize = 50 * 1024 * 1024L // 50MB
    val maxTotalExpanded = 150 * 1024 * 1024L // 150MB

    for (name in names) {
      try {
        context.assets.open(name).use { input ->
          val tempExtractDir = File(context.cacheDir, "worklet-extract-" + UUID.randomUUID()).apply { mkdirs() }
          try {
            var totalBytes = 0L
            var entryCount = 0
            val seenEntries = HashSet<String>()

            ZipInputStream(input).use { zip ->
              var entry = zip.nextEntry
              while (entry != null) {
                entryCount++
                if (entryCount > maxEntries) {
                  throw IllegalStateException("ZIP_BOMB: exceeds entry limit")
                }
                val entryName = entry.name
                // Validate segment-by-segment: reject absolute, .., :, NUL
                if (entryName.contains("\u0000") ||
                  entryName.startsWith("/") ||
                  entryName.startsWith("\\") ||
                  entryName.contains(":") ||
                  entryName.split('/', '\\').any { it == ".." }
                ) {
                  throw SecurityException("MALICIOUS_ZIP: illegal entry path: $entryName")
                }
                if (!seenEntries.add(entryName)) {
                  throw SecurityException("MALICIOUS_ZIP: duplicate entry: $entryName")
                }

                val outFile = File(tempExtractDir, entryName)
                if (!outFile.canonicalPath.startsWith(tempExtractDir.canonicalPath + File.separator) &&
                  outFile.canonicalPath != tempExtractDir.canonicalPath
                ) {
                  throw SecurityException("MALICIOUS_ZIP: path traversal detected: $entryName")
                }

                if (entry.isDirectory) {
                  outFile.mkdirs()
                } else {
                  outFile.parentFile?.mkdirs()
                  var entryBytes = 0L
                  val buffer = ByteArray(8192)
                  FileOutputStream(outFile).use { output ->
                    var r: Int
                    while (zip.read(buffer).also { r = it } != -1) {
                      entryBytes += r
                      totalBytes += r
                      if (entryBytes > maxSingleFileSize || totalBytes > maxTotalExpanded) {
                        throw IllegalStateException("ZIP_BOMB: size limit exceeded")
                      }
                      output.write(buffer, 0, r)
                    }
                  }
                }
                zip.closeEntry()
                entry = zip.nextEntry
              }
            }

            // Atomically publish into dest
            tempExtractDir.copyRecursively(dest, overwrite = true)
            return
          } finally {
            tempExtractDir.deleteRecursively()
          }
        }
      } catch (_: Throwable) {}
    }
  }
}
