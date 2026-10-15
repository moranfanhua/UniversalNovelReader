plugins {
    id("com.android.library")
}

android {
    namespace = "com.github.megatronking.netbare"
    compileSdk = 36
    defaultConfig { minSdk = 24 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("androidx.annotation:annotation:1.9.1")
    implementation("androidx.core:core:1.16.0")
    implementation("org.bouncycastle:bcpkix-jdk18on:1.83")
    implementation("com.google.guava:guava:33.4.8-android")
}
