import java.io.FileInputStream
import java.util.Properties

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}
val allowDebugSigning = providers.gradleProperty("musaic.allowDebugSigning")
    .map { it.toBoolean() }
    .getOrElse(false)

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.musaic"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.musaic"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    // ABI 分割：默认会把 x86_64 / arm64-v8a / armeabi-v7a 三套 native 库
    // 全部打进同一个 APK（实测各约 17–20MB，合计 ~56MB）。
    // x86_64 只用于模拟器，真机安装包完全不需要。
    // 开启后每个 ABI 产出独立 APK，用户只下载自己机型那一份。
    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "armeabi-v7a", "x86_64")
            isUniversalApk = true // 保留一个全量包，供分发给不确定机型时使用
        }
    }

    buildTypes {
        release {
            // R8 代码混淆 + 资源压缩。
            //
            // 关闭时（原先的状态）classes.dex 约 3.5MB 且**未做无用代码消除**；
            // Tika / Kotlin stdlib 等库中未被调用的部分会被全部保留。
            // Flutter 引擎与 Dart 代码（libapp.so）不受影响——
            // 那部分是 AOT 产物，与 R8 无关。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = when {
                keystorePropertiesFile.exists() -> signingConfigs.getByName("release")
                allowDebugSigning -> signingConfigs.getByName("debug")
                else -> null
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

tasks.configureEach {
    if (name == "assembleRelease" || name == "bundleRelease") {
        doFirst {
            if (!keystorePropertiesFile.exists() && !allowDebugSigning) {
                throw GradleException(
                    "Release signing requires android/key.properties; " +
                        "use -Pmusaic.allowDebugSigning=true only for local testing.",
                )
            }
        }
    }
}

flutter {
    source = "../.."
}
