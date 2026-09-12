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

// ---------------------------------------------------------------------------
// AGP 9 兼容性修复（可复现，替代 tool/patch_inappwebview_gradle.sh）
//
// flutter_inappwebview_android 1.1.3 的 build.gradle 使用
// getDefaultProguardFile('proguard-android.txt')；该文件自 AGP 9 起被移除，
// 构建会直接失败：
//   `getDefaultProguardFile('proguard-android.txt')` is no longer supported
//
// 官方在 master（1.2.0-beta.3）已改为 'proguard-android-optimize.txt'，
// 但 1.2.0-beta 系列要求 platform_interface ^1.4.0-beta，与父插件
// flutter_inappwebview 6.1.5 的 ^1.3.0 约束冲突，无法直接升级。
//
// 因此此处用 Gradle 的 beforeProject 钩子在配置阶段改写插件脚本源码。
// 时机在 pub 依赖解析之后、Gradle 评估之前，因此**不依赖 pub cache 的
// 既有状态**：干净环境（CI / 新机器）同样生效，无需手工打补丁。
// ---------------------------------------------------------------------------
val agp9CompatPatched = mutableSetOf<String>()

gradle.beforeProject {
    val proj = this
    if (proj.name != "flutter_inappwebview_android") return@beforeProject
    // 插件工程经 includeBuild/插件加载器加入，其 projectDir 指向
    // pub cache 下的 flutter_inappwebview_android-<ver>/android。
    // 依次尝试已知候选路径，命中即改写。
    val candidates = listOf(
        proj.file("build.gradle"),
        proj.projectDir.resolve("build.gradle"),
    )
    val script = candidates.firstOrNull { it.isFile } ?: return@beforeProject
    if (!agp9CompatPatched.add(script.canonicalPath)) return@beforeProject
    val original = script.readText()
    if (!original.contains("proguard-android.txt")) return@beforeProject
    script.writeText(
        original.replace(
            "getDefaultProguardFile('proguard-android.txt')",
            "getDefaultProguardFile('proguard-android-optimize.txt')",
        ),
    )
    logger.lifecycle(
        "Musaic: applied AGP 9 proguard compat fix to ${script.path}",
    )
}
