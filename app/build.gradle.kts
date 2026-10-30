plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.zertgoblin.app"
    compileSdk = 35

    defaultConfig {
        // Package identity: estate pattern is com.<game>.app (cf.
        // VOIDRUNNER com.voidrunner.app). This line (plus `namespace`
        // above) is the entire package-name decision — a one-line
        // change here renames the app.
        applicationId = "com.zertgoblin.app"
        minSdk = 28
        targetSdk = 35
        versionCode = 6
        versionName = "0.1.5"

        vectorDrawables { useSupportLibrary = true }
    }

    // Release signing comes ONLY from the environment (CI secrets).
    // Nothing secret is ever committed — see README.md.
    val keystoreFile: java.io.File? =
        System.getenv("KEYSTORE_FILE")?.let { file(it) }?.takeIf { it.exists() }
    if (keystoreFile != null) {
        signingConfigs {
            create("release") {
                storeFile = keystoreFile
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KEY_ALIAS")
                keyPassword = System.getenv("KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            isDebuggable = true
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Signed only when a keystore is provided (CI tag builds).
            // Otherwise falls back to the debug key — fine for local
            // testing, NOT for the store.
            if (keystoreFile != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures {
        buildConfig = true
    }

    packaging { resources { excludes += "/META-INF/{AL2.0,LGPL2.1}" } }
}

dependencies {
    implementation("androidx.core:core-ktx:1.16.0")
    // MainActivity is a ComponentActivity (MWA's ActivityResultSender
    // requires one); clientlib-ktx only carries this at runtime scope.
    implementation("androidx.activity:activity-ktx:1.10.1")
    // Document-start JavaScript for the wallet-bridge shim injection.
    implementation("androidx.webkit:webkit:1.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // Solana Mobile Wallet Adapter (official). Provides the native
    // connect / session / sign flow against the Seeker's Seed Vault
    // wallet. Docs: https://github.com/solana-mobile/solana-mobile-docs
    implementation("com.solanamobile:mobile-wallet-adapter-clientlib-ktx:2.0.8")
}
