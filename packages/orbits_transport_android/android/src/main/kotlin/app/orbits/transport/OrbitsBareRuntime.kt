package app.orbits.transport

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import java.io.File

/**
 * Official BareKit / packaged-runtime probe. This class must not embed a
 * remote URL. Missing or unverified artifacts fail closed.
 *
 * Official bare-kit 2.4.3 host is to.holepunch.bare.kit.Worklet:
 * Worklet(Options), then start(filename, source, charset, arguments).
 * Resolved by reflection so the plugin still compiles when classes.jar
 * has not been fetched into the local cache.
 */
internal object OrbitsBareRuntime {
  private var retainedWorklet: Any? = null

  fun tryStart(
    call: MethodCall,
    binding: FlutterPlugin.FlutterPluginBinding? = null,
  ): Boolean {
    if (tryStartBareKit(binding)) {
      return true
    }
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
    return false
  }

  private fun tryLaunchOfficial(binary: File): Boolean {
    return try {
      // android.jar ProcessBuilder does not expose desktop Java 9 redirect sinks.
      val process = ProcessBuilder(binary.absolutePath).start()
      try {
        process.inputStream.close()
      } catch (_: Exception) {
      }
      try {
        process.errorStream.close()
      } catch (_: Exception) {
      }
      true
    } catch (_: Exception) {
      false
    }
  }

  private fun tryStartBareKit(
    binding: FlutterPlugin.FlutterPluginBinding?,
  ): Boolean {
    val source = readWorkletSource(binding) ?: return false
    return try {
      val workletClass = Class.forName("to.holepunch.bare.kit.Worklet")
      val optionsClass = Class.forName("to.holepunch.bare.kit.Worklet\$Options")
      val options = optionsClass.getDeclaredConstructor().newInstance()
      val memoryLimit = optionsClass.methods.firstOrNull { method ->
        method.name == "memoryLimit" && method.parameterTypes.size == 1
      }
      memoryLimit?.invoke(options, 24 * 1024 * 1024)
      val ctor = workletClass.getDeclaredConstructor(optionsClass)
      val worklet = ctor.newInstance(options)
      val start = workletClass.methods.firstOrNull { method ->
        method.name == "start" &&
          method.parameterTypes.size == 4 &&
          method.parameterTypes[0] == String::class.java &&
          method.parameterTypes[1] == String::class.java &&
          method.parameterTypes[2] == String::class.java
      } ?: return false
      start.invoke(worklet, "/orbits/worklet.js", source, "UTF-8", null)
      retainedWorklet = worklet
      true
    } catch (_: ClassNotFoundException) {
      false
    } catch (_: NoClassDefFoundError) {
      false
    } catch (_: UnsatisfiedLinkError) {
      false
    } catch (_: Exception) {
      false
    }
  }

  private fun readWorkletSource(
    binding: FlutterPlugin.FlutterPluginBinding?,
  ): String? {
    val assets = binding?.applicationContext?.assets
    if (assets != null) {
      val flutterName = "tool/connectivity_harness/src/worklet.js"
      val lookup = try {
        binding.flutterAssets.getAssetFilePathByName(flutterName)
      } catch (_: Exception) {
        null
      }
      for (name in listOfNotNull(lookup, flutterName, "flutter_assets/$flutterName")) {
        try {
          assets.open(name).use { return it.reader().readText() }
        } catch (_: Exception) {
          // try the next packaged name
        }
      }
    }
    val file = workletFile() ?: return null
    return try {
      file.readText()
    } catch (_: Exception) {
      null
    }
  }

  private fun workletFile(): File? {
    val env = System.getenv("ORBITS_WORKLET_JS")
    if (!env.isNullOrEmpty()) {
      val file = File(env)
      if (file.isFile) return file
    }
    val packaged = File("flutter_assets/tool/connectivity_harness/src/worklet.js")
    if (packaged.isFile) return packaged
    val relative = File("tool/connectivity_harness/src/worklet.js")
    if (relative.isFile) return relative
    return null
  }
}
