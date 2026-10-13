import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseProperties = Properties().apply {
    val propertiesFile = rootProject.file("key.properties")
    if (propertiesFile.exists()) {
        propertiesFile.inputStream().use { load(it) }
    }
}
fun signingValue(property: String, environment: String): String? =
    System.getenv(environment)?.takeIf { it.isNotEmpty() }
        ?: releaseProperties.getProperty(property)?.takeIf { it.isNotEmpty() }

val releaseStore = signingValue("storeFile", "ANDROID_KEYSTORE_PATH")
val releaseStorePassword = signingValue("storePassword", "KEYSTORE_PASSWORD")
val releaseKeyPassword = signingValue("keyPassword", "KEY_PASSWORD")
val releaseAlias = signingValue("keyAlias", "KEY_ALIAS")
val hasReleaseSigning = listOf(
    releaseStore, releaseStorePassword, releaseKeyPassword, releaseAlias
).all { it != null }
if (System.getenv("UNR_REQUIRE_RELEASE_SIGNING") == "true") {
    require(hasReleaseSigning) { "发布构建缺少 Android 签名配置，请检查仓库 Secrets。" }
}

android {
    namespace = "io.github.moranfanhua.unr"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.moranfanhua.unr"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStore!!)
                storePassword = releaseStorePassword
                keyPassword = releaseKeyPassword
                keyAlias = releaseAlias
            }
        }
    }

    buildTypes {
        release {
            // 保留未配置密钥时的本机试用构建；CI 强制要求上面的正式签名。
            signingConfig = signingConfigs.getByName(if (hasReleaseSigning) "release" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
