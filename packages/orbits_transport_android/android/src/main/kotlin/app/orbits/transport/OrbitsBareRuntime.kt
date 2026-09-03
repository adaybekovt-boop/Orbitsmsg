package app.orbits.transport

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.io.File
import java.io.FileOutputStream
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.ZipInputStream

/**
 * Official BareKit / packaged-runtime host. This class must not embed a
 * remote URL. Missing or unverified artifacts fail closed.
 *
 * Official bare-kit 2.4.3 host is to.holepunch.bare.kit.Worklet:
 * Worklet(Options), then start(filename, source, StandardCharsets.UTF_8, args).
 * After start() returns, attach to.holepunch.bare.kit.IPC and speak OTP1.
 * Resolved by reflection so the plugin still compiles when the official
 * exploded AAR has not been linked into android/libs/bare-kit.
 */
internal object OrbitsBareRuntime {
  private val main = Handler(Looper.getMainLooper())
  private val nextId = AtomicInteger(1)
  @Volatile
  private var session: Session? = null

  fun tryStart(
    call: io.flutter.plugin.common.MethodCall,
    binding: FlutterPlugin.FlutterPluginBinding? = null,
  ): Boolean {
    return try {
      startSession(call.arguments as? Map<*, *>, binding)
      true
    } catch (_: Exception) {
      false
    }
  }

  @Synchronized
  fun startSession(
    args: Map<*, *>?,
    binding: FlutterPlugin.FlutterPluginBinding?,
  ): Map<String, Any?> {
    session?.terminateQuiet()
    session = null
    val context = binding?.applicationContext
      ?: throw IllegalStateException("BARE_RUNTIME_MISSING")
    val workletClass = try {
      Class.forName("to.holepunch.bare.kit.Worklet")
    } catch (_: ClassNotFoundException) {
      throw IllegalStateException("BARE_RUNTIME_MISSING")
    } catch (_: NoClassDefFoundError) {
      throw IllegalStateException("BARE_RUNTIME_MISSING")
    }
    val ipcClass = try {
      Class.forName("to.holepunch.bare.kit.IPC")
    } catch (_: ClassNotFoundException) {
      throw IllegalStateException("BARE_RUNTIME_MISSING")
    }
    val extracted = extractWorkletTree(context, binding)
    val source = extracted.readText()
    if (source.isEmpty()) throw IllegalStateException("BARE_WORKLET_FAILED")
    val storage = File(context.filesDir, "orbits-corestore").apply { mkdirs() }
    val backend = (args?.get("backend") as? String)?.takeIf { it.isNotEmpty() } ?: "hyperswarm"
    val argv = arrayOf(
      "--backend=$backend",
      "--storage=${storage.absolutePath}",
    )
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
    val created = Session(workletClass, ipcClass, worklet, ipc)
    attachReadable(ipcClass, ipc, created)
    session = created
    val startParams = LinkedHashMap<String, Any?>()
    startParams["peerId"] = args?.get("peerId")
    startParams["discoverySecret"] = args?.get("discoverySecret")
    startParams["relayForced"] = args?.get("relayForced") == true
    startParams["backend"] = backend
    startParams["requireRealCorestore"] = true
    startParams["storageDir"] = storage.absolutePath
    startParams["writerDeviceId"] = args?.get("deviceId") ?: args?.get("peerId")
    return created.request("start", startParams, 45_000)
  }

  fun request(method: String, params: Map<String, Any?>, timeoutMs: Long): Map<String, Any?> {
    val live = session ?: throw IllegalStateException("NOT_STARTED")
    return live.request(method, params, timeoutMs)
  }

  fun runtimeInfo(): Map<String, Any?> {
    val live = session ?: throw IllegalStateException("NOT_STARTED")
    return live.request("runtime.info", emptyMap(), 8_000)
  }

  fun suspendRuntime() {
    val live = session ?: return
    try {
      live.request("suspend", emptyMap(), 8_000)
    } catch (_: Exception) {
    }
    try {
      live.workletClass.getMethod("suspend").invoke(live.worklet)
    } catch (_: Exception) {
    }
  }

  fun resumeRuntime() {
    val live = session ?: return
    try {
      live.workletClass.getMethod("resume").invoke(live.worklet)
    } catch (_: Exception) {
    }
    live.request("resume", emptyMap(), 8_000)
  }

  @Synchronized
  fun stopSession() {
    val live = session
    session = null
    if (live == null) return
    try {
      live.request("stop", emptyMap(), 8_000)
    } catch (_: Exception) {
    }
    live.terminateQuiet()
  }

  fun isLive(): Boolean = session != null

  fun setEventSink(sink: ((Map<String, Any?>) -> Unit)?) {
    session?.eventSink = sink
  }

  private fun attachReadable(ipcClass: Class<*>, ipc: Any, session: Session) {
    val pollClass = Class.forName("to.holepunch.bare.kit.IPC\$PollCallback")
    val proxy = Proxy.newProxyInstance(pollClass.classLoader, arrayOf(pollClass)) { _, method, _ ->
      if (method.name == "apply") {
        session.drain()
      }
      null
    }
    ipcClass.getMethod("readable", pollClass).invoke(ipc, proxy)
  }

  private class Session(
    val workletClass: Class<*>,
    val ipcClass: Class<*>,
    val worklet: Any,
    val ipc: Any,
  ) {
    val pending = ConcurrentHashMap<Int, CompletableFuture<Map<String, Any?>>>()
    val decoder = Otp1.Decoder()
    @Volatile
    var eventSink: ((Map<String, Any?>) -> Unit)? = null
    private val writeLock = Any()

    fun request(method: String, params: Map<String, Any?>, timeoutMs: Long): Map<String, Any?> {
      if (pending.size >= 64) {
        throw IllegalStateException("IPC_BACKPRESSURE")
      }
      val id = nextId.getAndIncrement()
      val future = CompletableFuture<Map<String, Any?>>()
      pending[id] = future
      val frame = Otp1.encode(
        Otp1.REQUEST,
        mapOf(
          "id" to id,
          "method" to method,
          "params" to params,
        ),
      )
      write(frame)
      try {
        return future.get(timeoutMs, TimeUnit.MILLISECONDS)
      } catch (err: Exception) {
        pending.remove(id)
        throw IllegalStateException(err.message ?: "IPC_TIMEOUT", err)
      }
    }

    fun write(bytes: ByteArray) {
      synchronized(writeLock) {
        val buffer = ByteBuffer.wrap(bytes)
        ipcClass.getMethod("write", ByteBuffer::class.java).invoke(ipc, buffer)
      }
    }

    fun drain() {
      try {
        while (true) {
          val raw = ipcClass.getMethod("read").invoke(ipc) ?: break
          val chunk = bufferToBytes(raw) ?: break
          if (chunk.isEmpty()) break
          for (msg in decoder.add(chunk)) {
            handleMessage(msg)
          }
        }
      } catch (_: Exception) {
      }
    }

    private fun handleMessage(msg: Otp1.Message) {
      when (msg.type) {
        Otp1.RESPONSE -> {
          val id = (msg.body["id"] as? Number)?.toInt() ?: return
          val future = pending.remove(id) ?: return
          if (msg.body["ok"] == false) {
            future.completeExceptionally(
              IllegalStateException(msg.body["error"]?.toString() ?: "ipc error"),
            )
          } else {
            @Suppress("UNCHECKED_CAST")
            val result = (msg.body["result"] as? Map<String, Any?>) ?: emptyMap()
            future.complete(result)
          }
        }
        Otp1.EVENT -> {
          val flat = flattenEvent(msg.body)
          val sink = eventSink
          if (sink != null) {
            main.post { sink(flat) }
          }
        }
      }
    }

    fun terminateQuiet() {
      for (future in pending.values) {
        future.completeExceptionally(IllegalStateException("ipc closed"))
      }
      pending.clear()
      try {
        ipcClass.getMethod("close").invoke(ipc)
      } catch (_: Exception) {
      }
      try {
        workletClass.getMethod("terminate").invoke(worklet)
      } catch (_: Exception) {
      }
      try {
        workletClass.getMethod("close").invoke(worklet)
      } catch (_: Exception) {
      }
    }
  }

  private fun flattenEvent(body: Map<String, Any?>): Map<String, Any?> {
    @Suppress("UNCHECKED_CAST")
    val payload = (body["payload"] as? Map<String, Any?>) ?: emptyMap()
    val out = LinkedHashMap<String, Any?>()
    out["name"] = body["name"]
    out["peerId"] = payload["peerId"]
    out["channel"] = payload["channel"]
    out["path"] = payload["path"]
    out["frameB64"] = payload["frameB64"]
    val b64 = payload["frameB64"] as? String
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
      } catch (_: Exception) {
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
        } catch (_: Exception) {
        }
      }
      if (!copied && name == "worklet.js") {
        throw IllegalStateException("BARE_WORKLET_FAILED")
      }
    }
    extractModuleZip(context, dest)
    val script = File(dest, "worklet.js")
    if (!script.isFile || script.length() == 0L) {
      throw IllegalStateException("BARE_WORKLET_FAILED")
    }
    return script
  }

  private fun extractModuleZip(context: Context, dest: File) {
    val names = listOf(
      "orbits-worklet-modules.zip",
      "flutter_assets/orbits-worklet-modules.zip",
    )
    for (name in names) {
      try {
        context.assets.open(name).use { input ->
          ZipInputStream(input).use { zip ->
            var entry = zip.nextEntry
            while (entry != null) {
              val outFile = File(dest, entry.name)
              if (entry.isDirectory) {
                outFile.mkdirs()
              } else {
                outFile.parentFile?.mkdirs()
                FileOutputStream(outFile).use { output -> zip.copyTo(output) }
              }
              zip.closeEntry()
              entry = zip.nextEntry
            }
          }
        }
        return
      } catch (_: Exception) {
      }
    }
  }
}
