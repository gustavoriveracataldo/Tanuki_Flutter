import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun signingValue(propertyName: String, envName: String): String {
    return (System.getenv(envName) ?: keystoreProperties.getProperty(propertyName) ?: "").trim()
}

val releaseStoreFile = signingValue("storeFile", "TANUKI_ANDROID_KEYSTORE_PATH")
val releaseStorePassword = signingValue("storePassword", "TANUKI_ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "TANUKI_ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "TANUKI_ANDROID_KEY_PASSWORD")
val hasReleaseSigning = releaseStoreFile.isNotEmpty() &&
    releaseStorePassword.isNotEmpty() &&
    releaseKeyAlias.isNotEmpty() &&
    releaseKeyPassword.isNotEmpty()

android {
    namespace = "com.toonami.tanuki"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.toonami.tanuki"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = if (File(releaseStoreFile).isAbsolute) {
                    File(releaseStoreFile)
                } else {
                    rootProject.file(releaseStoreFile)
                }
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        maybeCreate("profile").apply {
            applicationIdSuffix = ".profile"
            versionNameSuffix = "-profile"
        }
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

gradle.taskGraph.whenReady {
    val requiresReleaseSigning = allTasks.any { task ->
        task.project == project && task.name in setOf(
            "assembleRelease",
            "bundleRelease",
            "packageRelease",
            "validateSigningRelease"
        )
    }
    if (requiresReleaseSigning && !hasReleaseSigning) {
        throw GradleException(
            "Release signing is not configured. Create android/key.properties or set " +
                "TANUKI_ANDROID_KEYSTORE_PATH, TANUKI_ANDROID_KEYSTORE_PASSWORD, " +
                "TANUKI_ANDROID_KEY_ALIAS and TANUKI_ANDROID_KEY_PASSWORD."
        )
    }
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}
