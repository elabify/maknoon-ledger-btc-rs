pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Consume the locally-built library-release.aar via flatDir.
        // Build it once with `make android` from the repo root before
        // building this app.
        flatDir {
            dirs("../../android/library/build/outputs/aar")
        }
    }
}

rootProject.name = "LedgerBtcExampleAndroid"
include(":app")
