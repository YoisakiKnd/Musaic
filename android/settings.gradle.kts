pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    // Flutter SDK 里 packages/flutter_tools/gradle/.gradle 与 build/
    // 若曾用 root 跑过构建，目录会变成 root 属主，includeBuild 无法写入。
    // 复制一份到本工程可写缓存，避开 SDK 里的 root 缓存。
    val flutterGradleSrc = file("$flutterSdkPath/packages/flutter_tools/gradle")
    val flutterGradleLocal = file("flutter-gradle-plugin")
    val stamp = file("${flutterGradleLocal.path}/.from-sdk")
    if (!stamp.isFile || stamp.readText() != flutterGradleSrc.canonicalPath) {
        flutterGradleLocal.deleteRecursively()
        flutterGradleLocal.mkdirs()
        flutterGradleSrc
            .walkTopDown()
            .onEnter { dir -> dir.name != ".gradle" && dir.name != "build" }
            .forEach { file ->
                val target = flutterGradleLocal.resolve(file.relativeTo(flutterGradleSrc))
                if (file.isDirectory) {
                    target.mkdirs()
                } else {
                    file.copyTo(target, overwrite = true)
                }
            }
        stamp.writeText(flutterGradleSrc.canonicalPath)
    }

    includeBuild(flutterGradleLocal.path)

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
