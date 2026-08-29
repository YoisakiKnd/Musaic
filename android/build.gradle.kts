allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// flutter_inappwebview_android 1.1.3 仍引用 AGP 9 已删除的 proguard-android.txt。
subprojects {
    afterEvaluate {
        if (name != "flutter_inappwebview_android") return@afterEvaluate
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        runCatching {
            val buildTypes = androidExt.javaClass.methods
                .first { it.name == "getBuildTypes" }
                .invoke(androidExt)
            val release = buildTypes.javaClass.methods
                .first { it.name == "findByName" }
                .invoke(buildTypes, "release") ?: return@runCatching
            release.javaClass.methods
                .first { it.name == "setMinifyEnabled" }
                .invoke(release, false)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
