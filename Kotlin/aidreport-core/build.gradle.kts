import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.kotlin.serialization)
    `maven-publish`
}

group = "io.github.codebymini"
version = "0.1.0"

kotlin {
    // Android consumes the JVM variant; the iOS targets match AndroidAPS's own.
    jvm {
        compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
    }
    iosArm64()
    iosSimulatorArm64()

    sourceSets {
        all {
            languageSettings.optIn("kotlin.time.ExperimentalTime")
            languageSettings.optIn("kotlin.uuid.ExperimentalUuidApi")
        }
        commonMain.dependencies {
            api(libs.kotlinx.datetime)
            api(libs.kotlinx.serialization.json)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.kotlinx.coroutines.test)
        }
    }
}

// The fixtures both implementations must reproduce, at the root of the repository.
// The reports Kotlin builds from them are written to build/fixture-output.
val fixtures = rootDir.resolve("../Fixtures/reports").canonicalPath
val fixtureOutput = layout.buildDirectory.dir("fixture-output").get().asFile.path
tasks.withType<Test>().configureEach {
    systemProperty("aidreport.fixtures", fixtures)
    systemProperty("aidreport.fixtureOutput", fixtureOutput)
}
