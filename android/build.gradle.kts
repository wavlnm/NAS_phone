allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
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
subprojects {
    project.evaluationDependsOn(":app")
}

// 部分插件仍固定 compileSdk 34，而新版 Flutter 插件 AAR 要求至少 36。
// 统一把各插件模块的 compileSdk 抬到 36，避免 AAR 元数据校验失败。
subprojects {
    val raiseCompileSdk = {
        val androidExtension = extensions.findByName("android")
        if (androidExtension != null) {
            runCatching {
                androidExtension.javaClass.methods
                    .firstOrNull { it.name == "setCompileSdk" && it.parameterCount == 1 }
                    ?.invoke(androidExtension, 36)
            }
        }
    }
    if (state.executed) {
        raiseCompileSdk()
    } else {
        afterEvaluate { raiseCompileSdk() }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
