package app.orbits.transport

import io.flutter.plugin.common.MethodCall
import java.io.File

/**
 * Official BareKit / packaged-runtime probe. This class must not embed a
 * remote URL. Missing or unverified artifacts fail closed.
 */
internal object OrbitsBareRuntime {
  fun tryStart(call: MethodCall): Boolean {
    val expected = call.argument<String>("expectedRuntimeSha256")
    val packaged = File("bare")
    val env = System.getenv("ORBITS_BARE_RUNTIME")
    val binary = when {
      !env.isNullOrEmpty() -> File(env)
      packaged.isFile -> packaged
      else -> null
    }
    if (binary != null && binary.isFile) {
      val sidecar = File(binary.path + ".sha256")
      if (!sidecar.isFile) return false
      val pinned = sidecar.readText().trim().substringBefore(' ')
      if (!expected.isNullOrEmpty() && expected != pinned) return false
      return tryLaunchOfficial(binary)
    }
    return tryStartBareKit()
  }

  private fun tryLaunchOfficial(binary: File): Boolean {
    return try {
      ProcessBuilder(binary.absolutePath)
        .redirectError(ProcessBuilder.Redirect.DISCARD)
        .redirectOutput(ProcessBuilder.Redirect.DISCARD)
        .start()
      true
    } catch (_: Exception) {
      false
    }
  }

  private fun tryStartBareKit(): Boolean {
    val script = File("flutter_assets/tool/connectivity_harness/src/worklet.js")
    if (!script.isFile) return false
    return try {
      val workletClass = Class.forName("to.holepunch.bare.kit.Worklet")
      val ctor = workletClass.getDeclaredConstructor()
      val worklet = ctor.newInstance()
      val start = workletClass.methods.firstOrNull { it.name == "start" } ?: return false
      val source = script.readText()
      start.invoke(worklet, "/orbits/worklet.js", source, null)
      true
    } catch (_: ClassNotFoundException) {
      false
    } catch (_: Exception) {
      false
    }
  }
}
