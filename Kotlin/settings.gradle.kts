pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}

rootProject.name = "aidreport"

// Models, statistics, validation and report definitions: the Kotlin side of the Swift
// AIDReportKit target, checked against the same fixtures in ../Fixtures/reports.
include(":aidreport-core")
