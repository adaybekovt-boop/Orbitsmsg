plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// GH-C01 / U-5: release signing is env-driven and never falls back to the
// Android debug keystore. `flutter run` / assembleDebug still use the
// implicit debug config. Missing env at configuration time is allowed so
// those debug tasks keep working; assembleRelease / bundleRelease fail in
// `whenReady` instead (see docs/android-signing.md).
val uploadStorePath: String = System.getenv("ORBITS_UPLOAD_STORE_FILE") ?: ""
val uploadStorePassword: String = System.getenv("ORBITS_UPLOAD_STORE_PASSWORD") ?: ""
val uploadKeyAlias: String = System.getenv("ORBITS_UPLOAD_KEY_ALIAS") ?: ""
val uploadKeyPassword: String = System.getenv("ORBITS_UPLOAD_KEY_PASSWORD") ?: ""

fun releaseSigningConfigured(): Boolean {
    if (uploadStorePath.isBlank() ||
        uploadStorePassword.isBlank() ||
        uploadKeyAlias.isBlank() ||
        uploadKeyPassword.isBlank()
    ) {
        return false
    }
    return file(uploadStorePath).isFile
}

android {
    namespace = "com.orbits.orbits_flutter"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.orbits.orbits_flutter"
        minSdk = 23
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // ORBITS_RELEASE_SIGNING
    signingConfigs {
        create("release") {
            if (uploadStorePath.isNotBlank()) {
                storeFile = file(uploadStorePath)
            }
            storePassword = uploadStorePassword
            keyAlias = uploadKeyAlias
            keyPassword = uploadKeyPassword
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

gradle.taskGraph.whenReady {
    val needsReleaseSigning = gradle.taskGraph.allTasks.any { task ->
        val n = task.name
        n.contains("Release") && (
            n.startsWith("assemble") ||
                n.startsWith("bundle") ||
                n.startsWith("package")
            )
    }
    if (needsReleaseSigning && !releaseSigningConfigured()) {
        throw org.gradle.api.GradleException(
            "Release builds require ORBITS_UPLOAD_STORE_FILE, " +
                "ORBITS_UPLOAD_STORE_PASSWORD, ORBITS_UPLOAD_KEY_ALIAS, and " +
                "ORBITS_UPLOAD_KEY_PASSWORD pointing at a real keystore. " +
                "There is no debug-keystore fallback (GH-C01 / U-5). " +
                "See docs/android-signing.md."
        )
    }
}

flutter {
    source = "../.."
}
