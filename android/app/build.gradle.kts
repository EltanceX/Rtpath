plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val rtpathTestHost = providers.gradleProperty("rtpathTestHost").orNull == "true"

android {
    namespace = "io.github.eltancex.rtpath"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.eltancex.rtpath"
        minSdk = 29
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    if (rtpathTestHost) {
        buildTypes.configureEach {
            if (name == "debug" || name == "profile") applicationIdSuffix = ".testhost"
        }
        sourceSets {
            getByName("main").java.srcDir("src/testhost/kotlin")
            for (buildType in listOf("debug", "profile")) {
                maybeCreate(buildType).manifest.srcFile("src/testhost/AndroidManifest.xml")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.sqlite:sqlite-bundled:2.6.2")
}
