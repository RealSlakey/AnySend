plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.slakey.anysend"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.slakey.anysend"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
        viewBinding = true
        aidl = true
    }
}

// The Tailscale tsnet AAR is optional. When it is absent (e.g. local dev
// without gomobile), we compile a stub Tsnetbridge class instead so the
// project still builds and can run in Direct LAN Mode.
val tsnetbridgeAar = file("libs/tsnetbridge.aar")
android.sourceSets.getByName("main") {
    if (!tsnetbridgeAar.exists()) {
        java.srcDir("src/stub/java")
        // The stub compiles and runs (Direct LAN Mode only), but every
        // tailnet feature silently dies. Make that impossible to miss.
        logger.warn(
            "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n" +
            "  libs/tsnetbridge.aar is MISSING - compiling the stub instead.\n" +
            "  The APK will build, but all Tailscale/tsnet features are dead.\n" +
            "  Build it first: scripts/build-aar.sh (needs Go + Android NDK)\n" +
            "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        )
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.activity:activity-ktx:1.8.2")
    implementation("androidx.recyclerview:recyclerview:1.3.2")

    // Networking & coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("com.google.code.gson:gson:2.10.1")

    // Shizuku: hotspot control runs in a shell-UID UserService process
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")

    // Tailscale tsnet bridge AAR (built from go/tsnetbridge via gomobile).
    // Optional: if absent, the stub in src/stub/java is used instead.
    if (tsnetbridgeAar.exists()) {
        implementation(files("libs/tsnetbridge.aar"))
    }

    testImplementation("junit:junit:4.13.2")
}
