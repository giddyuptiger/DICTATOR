// Root build file. Plugin versions are declared here with `apply false` and applied
// in the module build files. Kotlin 1.9.24 is paired with Compose compiler 1.5.14
// (a compatible pair) so the setup screen can be written in Jetpack Compose.
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
