package app.orbits.transport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class Otp1Test {

  @Test
  fun testEncodeDecodeRoundtrip() {
    val decoder = Otp1.Decoder()
    val frame = Otp1.encode(
      Otp1.REQUEST,
      mapOf(
        "id" to 42,
        "method" to "start",
        "params" to mapOf("peerId" to "ORBIT-TEST"),
      ),
    )
    val messages = decoder.add(frame)
    assertEquals(1, messages.size)
    val msg = messages[0]
    assertEquals(Otp1.REQUEST, msg.type)
    assertEquals(42, (msg.body["id"] as Number).toInt())
    assertEquals("start", msg.body["method"])
    assertEquals(0, decoder.bufferedBytes())
  }

  @Test
  fun testSplitFrameDelivery() {
    val decoder = Otp1.Decoder()
    val frame = Otp1.encode(
      Otp1.EVENT,
      mapOf(
        "name" to "connected",
        "peerId" to "ORBIT-SPLIT",
      ),
    )
    val out = mutableListOf<Otp1.Message>()
    // Feed 3 bytes at a time
    for (i in frame.indices step 3) {
      val end = minOf(i + 3, frame.size)
      val slice = frame.copyOfRange(i, end)
      out.addAll(decoder.add(slice))
    }
    assertEquals(1, out.size)
    assertEquals("connected", out[0].body["name"])
    assertEquals("ORBIT-SPLIT", out[0].body["peerId"])
    assertEquals(0, decoder.bufferedBytes())
  }

  @Test
  fun testCoalescedFrames() {
    val decoder = Otp1.Decoder()
    val frame1 = Otp1.encode(Otp1.RESPONSE, mapOf("id" to 1, "ok" to true))
    val frame2 = Otp1.encode(Otp1.RESPONSE, mapOf("id" to 2, "ok" to true))
    val combined = ByteArray(frame1.size + frame2.size)
    System.arraycopy(frame1, 0, combined, 0, frame1.size)
    System.arraycopy(frame2, 0, combined, frame1.size, frame2.size)

    val messages = decoder.add(combined)
    assertEquals(2, messages.size)
    assertEquals(1, (messages[0].body["id"] as Number).toInt())
    assertEquals(2, (messages[1].body["id"] as Number).toInt())
    assertEquals(0, decoder.bufferedBytes())
  }

  @Test
  fun testBadMagicResetsBufferAndDoesNotPoisonSubsequentFrames() {
    val decoder = Otp1.Decoder()
    val badHeader = ByteBuffer.allocate(10).order(ByteOrder.BIG_ENDIAN)
      .putInt(0xDEADBEEF.toInt())
      .put(1) // version
      .put(1) // type
      .putInt(10) // len
      .array()

    try {
      decoder.add(badHeader)
      fail("expected Otp1DecodeException")
    } catch (e: Otp1.Otp1DecodeException) {
      assertEquals("BAD_MAGIC", e.code)
    }

    assertEquals(0, decoder.bufferedBytes())

    // Subsequent valid frame must decode cleanly without being corrupted by the bad frame
    val validFrame = Otp1.encode(Otp1.RESPONSE, mapOf("id" to 99, "ok" to true))
    val messages = decoder.add(validFrame)
    assertEquals(1, messages.size)
    assertEquals(99, (messages[0].body["id"] as Number).toInt())
  }

  @Test
  fun testBadVersionResetsBufferAndDoesNotPoisonSubsequentFrames() {
    val decoder = Otp1.Decoder()
    val badHeader = ByteBuffer.allocate(10).order(ByteOrder.BIG_ENDIAN)
      .putInt(Otp1.MAGIC)
      .put(99) // invalid version != 1
      .put(1)
      .putInt(10)
      .array()

    try {
      decoder.add(badHeader)
      fail("expected Otp1DecodeException")
    } catch (e: Otp1.Otp1DecodeException) {
      assertEquals("BAD_VERSION", e.code)
    }

    assertEquals(0, decoder.bufferedBytes())

    val validFrame = Otp1.encode(Otp1.RESPONSE, mapOf("id" to 100, "ok" to true))
    val messages = decoder.add(validFrame)
    assertEquals(1, messages.size)
    assertEquals(100, (messages[0].body["id"] as Number).toInt())
  }

  @Test
  fun testOversizeFrameResetsBufferAndRejectsPayload() {
    val decoder = Otp1.Decoder()
    val badHeader = ByteBuffer.allocate(10).order(ByteOrder.BIG_ENDIAN)
      .putInt(Otp1.MAGIC)
      .put(1) // version
      .put(1) // type
      .putInt(Otp1.MAX_PAYLOAD + 1) // oversized
      .array()

    try {
      decoder.add(badHeader)
      fail("expected Otp1DecodeException")
    } catch (e: Otp1.Otp1DecodeException) {
      assertEquals("OVERSIZE_FRAME", e.code)
    }

    assertEquals(0, decoder.bufferedBytes())

    val validFrame = Otp1.encode(Otp1.RESPONSE, mapOf("id" to 101, "ok" to true))
    val messages = decoder.add(validFrame)
    assertEquals(1, messages.size)
    assertEquals(101, (messages[0].body["id"] as Number).toInt())
  }

  @Test
  fun testMalformedJsonResetsBufferAndDoesNotPoisonSubsequentFrames() {
    val decoder = Otp1.Decoder()
    val corruptBytes = "{ invalid json payload: ".toByteArray(Charsets.UTF_8)
    val header = ByteBuffer.allocate(10).order(ByteOrder.BIG_ENDIAN)
      .putInt(Otp1.MAGIC)
      .put(1)
      .put(1)
      .putInt(corruptBytes.size)
      .array()
    val corruptFrame = ByteArray(10 + corruptBytes.size)
    System.arraycopy(header, 0, corruptFrame, 0, 10)
    System.arraycopy(corruptBytes, 0, corruptFrame, 10, corruptBytes.size)

    try {
      decoder.add(corruptFrame)
      fail("expected Otp1DecodeException")
    } catch (e: Otp1.Otp1DecodeException) {
      assertEquals("MALFORMED_JSON", e.code)
    }

    assertEquals(0, decoder.bufferedBytes())

    val validFrame = Otp1.encode(Otp1.RESPONSE, mapOf("id" to 102, "ok" to true))
    val messages = decoder.add(validFrame)
    assertEquals(1, messages.size)
    assertEquals(102, (messages[0].body["id"] as Number).toInt())
  }
}
