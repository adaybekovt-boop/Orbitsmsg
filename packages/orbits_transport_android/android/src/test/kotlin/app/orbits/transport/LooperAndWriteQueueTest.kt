package app.orbits.transport

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class LooperAndWriteQueueTest {

  @Test
  fun testLooperRequirementOnThreads() {
    // Plain thread has no Looper
    val plainThreadLooperNull = AtomicBoolean(false)
    val t = Thread {
      if (Looper.myLooper() == null) {
        plainThreadLooperNull.set(true)
      }
    }
    t.start()
    t.join()
    assertTrue("plain java thread must have null Looper", plainThreadLooperNull.get())

    // HandlerThread has a prepared Looper
    val ht = HandlerThread("test-bare-ipc")
    ht.start()
    val htLooperNotNull = AtomicBoolean(false)
    val latch = CountDownLatch(1)
    val handler = Handler(ht.looper)
    handler.post {
      if (Looper.myLooper() != null) {
        htLooperNotNull.set(true)
      }
      latch.countDown()
    }
    latch.await(5, TimeUnit.SECONDS)
    ht.quitSafely()
    assertTrue("HandlerThread must have prepared Looper", htLooperNotNull.get())
  }

  // Mock IPC class to verify OutboundWriteQueue logic
  class MockIpc(val maxChunkSize: Int = 16) {
    val writtenBytes = ByteArrayOutputStream()
    var writeCallCount = 0

    fun write(buf: ByteBuffer): Int {
      writeCallCount++
      val toWrite = minOf(buf.remaining(), maxChunkSize)
      val slice = ByteArray(toWrite)
      buf.get(slice)
      writtenBytes.write(slice)
      return toWrite
    }
  }

  @Test
  fun testWriteQueueBackpressureOnFrameCount() {
    val ht = HandlerThread("test-wq-frames")
    ht.start()
    val handler = Handler(ht.looper)
    val mock = MockIpc()
    val queue = OrbitsBareRuntime.OutboundWriteQueue(
      MockIpc::class.java,
      mock,
      handler,
      maxFrames = 64,
      maxBytes = 2 * 1024 * 1024,
    )

    try {
      val frame = ByteArray(10) { 1 }
      for (i in 1..64) {
        queue.enqueue(frame)
      }
      // 65th frame must trigger backpressure
      try {
        queue.enqueue(frame)
        fail("expected backpressure on 65th frame")
      } catch (e: IllegalStateException) {
        assertEquals("IPC_BACKPRESSURE", e.message)
      }
    } finally {
      ht.quitSafely()
    }
  }

  @Test
  fun testWriteQueueBackpressureOnByteLimit() {
    val ht = HandlerThread("test-wq-bytes")
    ht.start()
    val handler = Handler(ht.looper)
    val mock = MockIpc()
    val queue = OrbitsBareRuntime.OutboundWriteQueue(
      MockIpc::class.java,
      mock,
      handler,
      maxFrames = 64,
      maxBytes = 1000,
    )

    try {
      val largeFrame = ByteArray(600) { 1 }
      queue.enqueue(largeFrame)
      // Next 600-byte frame exceeds 1000 bytes limit
      try {
        queue.enqueue(largeFrame)
        fail("expected backpressure on byte limit")
      } catch (e: IllegalStateException) {
        assertEquals("IPC_BACKPRESSURE", e.message)
      }
    } finally {
      ht.quitSafely()
    }
  }

  @Test
  fun testWriteQueueHandlesPartialWritesWithoutByteInterleaving() {
    val ht = HandlerThread("test-wq-partial")
    ht.start()
    val handler = Handler(ht.looper)
    // Mock IPC that only writes 5 bytes at a time
    val mock = MockIpc(maxChunkSize = 5)
    val queue = OrbitsBareRuntime.OutboundWriteQueue(
      MockIpc::class.java,
      mock,
      handler,
      maxFrames = 64,
      maxBytes = 2 * 1024 * 1024,
    )

    try {
      val frame1 = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
      val frame2 = byteArrayOf(11, 12, 13, 14, 15)
      queue.enqueue(frame1)
      queue.enqueue(frame2)

      // Wait for handler thread to process pump
      val latch = CountDownLatch(1)
      handler.post {
        // Run pump until empty
        queue.pump()
        latch.countDown()
      }
      latch.await(5, TimeUnit.SECONDS)

      val all = mock.writtenBytes.toByteArray()
      assertEquals(15, all.size)
      // Verify byte ordering is exactly frame1 followed by frame2 (no interleaving)
      for (i in 0..9) {
        assertEquals((i + 1).toByte(), all[i])
      }
      for (i in 10..14) {
        assertEquals((i + 1).toByte(), all[i])
      }
    } finally {
      ht.quitSafely()
    }
  }
}
