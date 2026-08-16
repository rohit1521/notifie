allprojects {
    repositories {
        google()
        mavenCentral()
        // The Notifie Android SDK is not on a public repository yet, so this
        // example resolves it from the local Maven cache. Publish it first with:
        //   cd examples/android && ./gradlew :notifie:publishToMavenLocal
        // Remove once dev.notifie:notifie-android is released.
        mavenLocal()
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
