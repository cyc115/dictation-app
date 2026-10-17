plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

/**
 * The Mac app's built-in setups and polish prompts, read from Setups.swift at build time, so both
 * apps send the same models and prompts with nothing to keep in sync by hand. Parses the string
 * constants exactly as bench/suites/polish.py's swift_string() does.
 */
abstract class ExtractSpec : DefaultTask() {
    @get:InputFile
    abstract val swift: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun extract() {
        val source = swift.get().asFile.readText()
        val constants = Regex("static let (\\w+) = \"\"\"\\n(.*?)\\n\\s*\"\"\"", RegexOption.DOT_MATCHES_ALL)
            .findAll(source).associate { it.groupValues[1] to swiftString(it.groupValues[2]) }
        val prompts = constants.filterKeys { Regex("v\\d+").matches(it) }
        val setups = constants["builtInJSON"]
        if (setups == null || prompts.isEmpty()) throw GradleException("no builtInJSON or prompts in ${swift.get().asFile}")
        val dir = outputDir.get().asFile.resolve("spec").apply { deleteRecursively(); mkdirs() }
        dir.resolve("setups.json").writeText(setups)
        dir.resolve("prompts").mkdirs()
        prompts.forEach { (version, text) -> dir.resolve("prompts/$version.txt").writeText(text) }
    }

    /** A Swift multi-line string body: indentation dropped; a trailing backslash joins the next line. */
    private fun swiftString(body: String): String =
        body.lines().map { it.trim() }
            .joinToString("") { if (it.endsWith("\\")) it.dropLast(1) else it + "\n" }.trim()
}

val extractSpec = tasks.register<ExtractSpec>("extractSpec") {
    swift.set(rootProject.layout.projectDirectory.file("../Sources/DictationKit/Setups.swift"))
    outputDir.set(layout.buildDirectory.dir("generated/spec"))
}

android {
    namespace = "app.dictation.keyboard"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.dictation.keyboard"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(extractSpec, ExtractSpec::outputDir)
    }
}

tasks.withType<Test>().configureEach {
    // Tests compare the extracted spec with the benchmarked prompt files and render screenshots.
    dependsOn(extractSpec)
    // Robolectric reaches FileDescriptor internals on JDK 17+.
    jvmArgs("--add-opens=java.base/java.io=ALL-UNNAMED", "--add-exports=java.base/jdk.internal.access=ALL-UNNAMED")
    systemProperty("specDir", extractSpec.get().outputDir.get().asFile.path)
    systemProperty("repoRoot", rootProject.layout.projectDirectory.dir("..").asFile.canonicalPath)
    systemProperty("screenshots", layout.buildDirectory.dir("screenshots").get().asFile.path)
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    testImplementation("org.json:json:20250517")
    testImplementation("org.robolectric:robolectric:4.17")
    testImplementation("androidx.test:core:1.7.0")
}
