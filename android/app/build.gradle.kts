plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "design.irons.dictator"
    compileSdk = 34

    defaultConfig {
        applicationId = "design.irons.dictator"
        // minSdk 26 (Android 8.0): InputMethodService, AudioRecord and the modern
        // networking stack are all comfortably available here.
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
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

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    composeOptions {
        // Compatible with Kotlin 1.9.24.
        kotlinCompilerExtensionVersion = "1.5.14"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")

    // Coroutines: recording and the network round trip run off the main thread.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // OkHttp for the multipart POST to /v1/dictate. Chosen over raw
    // HttpURLConnection because MultipartBody makes the file+fields body correct
    // and readable, and connection pooling keeps the TLS connection warm.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Jetpack Compose, used only by the setup MainActivity (the keyboard itself is
    // a classic View, which is the right tool for an InputMethodService input view).
    val composeBom = platform("androidx.compose:compose-bom:2024.06.00")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.9.1")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.4")
}
