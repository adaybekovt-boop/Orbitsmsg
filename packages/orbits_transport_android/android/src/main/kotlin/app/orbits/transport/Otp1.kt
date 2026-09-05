package app.orbits.transport

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * orbits-bare-ipc-v1 (OTP1) frames. Magic 0x4F545031, version 1.
 * Host IPC is raw bytes; JSON lives only inside the payload.
 */
internal object Otp1 {
  const val MAGIC = 0x4F545031
  const val VERSION = 1
  const val REQUEST = 1
  const val RESPONSE = 2
  const val EVENT = 3
  const val MAX_PAYLOAD = 256 * 1024

  fun encode(type: Int, body: Map<String, Any?>): ByteArray {
    val payload = jsonObject(body).toString().toByteArray(Charsets.UTF_8)
    if (payload.size > MAX_PAYLOAD) {
      throw IllegalArgumentException("IPC_FRAME")
    }
    val header = ByteBuffer.allocate(10).order(ByteOrder.BIG_ENDIAN)
    header.putInt(MAGIC)
    header.put(VERSION.toByte())
    header.put(type.toByte())
    header.putInt(payload.size)
    val out = ByteArrayOutputStream(10 + payload.size)
    out.write(header.array())
    out.write(payload)
    return out.toByteArray()
  }

  class Otp1DecodeException(val code: String, message: String, cause: Throwable? = null) :
    IllegalStateException(message, cause)

  class Decoder {
    private val buf = ByteArrayOutputStream()

    @Synchronized
    fun reset() {
      buf.reset()
    }

    @Synchronized
    fun bufferedBytes(): Int = buf.size()

    @Synchronized
    fun add(chunk: ByteArray): List<Message> {
      if (chunk.isNotEmpty()) buf.write(chunk)
      val data = buf.toByteArray()
      val out = ArrayList<Message>()
      var offset = 0
      try {
        while (offset + 10 <= data.size) {
          val header = ByteBuffer.wrap(data, offset, 10).order(ByteOrder.BIG_ENDIAN)
          val magic = header.int
          if (magic != MAGIC) {
            reset()
            throw Otp1DecodeException("BAD_MAGIC", "bad IPC magic: 0x" + Integer.toHexString(magic))
          }
          val version = header.get().toInt() and 0xff
          if (version != VERSION) {
            reset()
            throw Otp1DecodeException("BAD_VERSION", "unsupported IPC version: $version")
          }
          val type = header.get().toInt() and 0xff
          val len = header.int
          if (len < 0 || len > MAX_PAYLOAD) {
            reset()
            throw Otp1DecodeException("OVERSIZE_FRAME", "IPC frame length out of bounds: $len")
          }
          if (offset + 10 + len > data.size) break
          val payload = String(data, offset + 10, len, Charsets.UTF_8)
          val json = try {
            JSONObject(payload)
          } catch (e: Exception) {
            reset()
            throw Otp1DecodeException("MALFORMED_JSON", "malformed JSON payload: ${e.message}", e)
          }
          out.add(Message(type, jsonToMap(json)))
          offset += 10 + len
        }
        if (offset > 0) {
          val remain = if (offset < data.size) data.copyOfRange(offset, data.size) else ByteArray(0)
          buf.reset()
          if (remain.isNotEmpty()) buf.write(remain)
        }
        return out
      } catch (e: Otp1DecodeException) {
        reset()
        throw e
      } catch (e: Exception) {
        reset()
        throw Otp1DecodeException("DECODE_ERROR", e.message ?: "decode error", e)
      }
    }
  }

  data class Message(val type: Int, val body: Map<String, Any?>)

  fun jsonObject(value: Map<String, Any?>): JSONObject {
    val obj = JSONObject()
    for ((k, v) in value) {
      obj.put(k, toJson(v))
    }
    return obj
  }

  private fun toJson(value: Any?): Any {
    return when (value) {
      null -> JSONObject.NULL
      is Map<*, *> -> {
        val obj = JSONObject()
        for ((k, v) in value) {
          if (k != null) obj.put(k.toString(), toJson(v))
        }
        obj
      }
      is List<*> -> {
        val arr = JSONArray()
        for (item in value) arr.put(toJson(item))
        arr
      }
      is ByteArray -> android.util.Base64.encodeToString(value, android.util.Base64.NO_WRAP)
      is Boolean, is Int, is Long, is Double, is String -> value
      is Float -> value.toDouble()
      is Number -> value
      else -> value.toString()
    }
  }

  fun jsonToMap(obj: JSONObject): Map<String, Any?> {
    val out = LinkedHashMap<String, Any?>()
    val keys = obj.keys()
    while (keys.hasNext()) {
      val key = keys.next()
      out[key] = fromJson(obj.get(key))
    }
    return out
  }

  private fun fromJson(value: Any?): Any? {
    return when (value) {
      null, JSONObject.NULL -> null
      is JSONObject -> jsonToMap(value)
      is JSONArray -> {
        val list = ArrayList<Any?>(value.length())
        for (i in 0 until value.length()) list.add(fromJson(value.get(i)))
        list
      }
      else -> value
    }
  }
}
