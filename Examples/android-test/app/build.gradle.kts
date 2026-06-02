plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.benjaminchodroff.ledgerbtcexample"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.benjaminchodroff.ledgerbtcexample"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    // .aar from ../../android/library/ pulled via flatDir in
    // settings.gradle.kts; declared as a regular dependency below.
    packaging {
        // Ledger app library + JNA both ship .so files in their .aar;
        // ensure no duplicate-file conflicts when bundling.
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    // The locally-built Rust core, consumed via flatDir.
    implementation(group = "", name = "library-release", ext = "aar")

    // JNA at runtime for UniFFI's Kotlin bindings.
    implementation("net.java.dev.jna:jna:5.14.0@aar")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // Compose UI.
    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
