# Local APK Build Instructions

## Prerequisites
- Flutter SDK (export PATH with flutter-sdk/bin)
- Android SDK at $HOME/android-sdk
- Java 17
- Python 3.11 (for Chaquopy/yt-dlp)
- Release keystore at ~/release.keystore with key.properties pointing to it

## Memory-Conscious Build
This build is **memory-intensive** due to:
- Flutter compilation
- Gradle with Android SDK processing
- Chaquopy (Python) building native libs for 3 ABIs (arm64-v8a, armeabi-v7a, x86_64)
- yt-dlp pip install during build

**CRITICAL**: Always use these exact memory limits or the build will fail — either OOM-killed or Kotlin daemon won't start:

```bash
export GRADLE_OPTS="-Xmx1200m -XX:MaxMetaspaceSize=256m -XX:+UseG1GC -Dkotlin.compiler.execution.strategy=direct"
export _JAVA_OPTIONS="-Xmx1200m -XX:MaxMetaspaceSize=256m"
```

- `-Xmx1200m` — 800m fails (Kotlin daemon can't connect), 2g+ gets OOM-killed
- `-Dkotlin.compiler.execution.strategy=direct` — bypasses Kotlin daemon, avoids its connection issues under memory pressure

## Build Command
```bash
export PATH="$HOME/flutter-sdk/bin:$PATH"
export FLUTTER_SUPPRESS_ANALYTICS=1
export ANDROID_SDK_ROOT="$HOME/android-sdk"
export ANDROID_HOME="$HOME/android-sdk"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export GRADLE_OPTS="-Xmx1200m -XX:MaxMetaspaceSize=256m -XX:+UseG1GC -Dkotlin.compiler.execution.strategy=direct"
export _JAVA_OPTIONS="-Xmx1200m -XX:MaxMetaspaceSize=256m"

flutter clean
flutter pub get
flutter build apk --release
```

## Post-Build Verification
```bash
~/android-sdk/build-tools/35.0.0/apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
# Should show: CN=Musly (not Android Debug)
```

## Upload to Release
```bash
gh release upload v2.0.3 build/app/outputs/flutter-apk/app-release.apk --clobber --repo tbrackbill/Musly
```

## Notes
- Keep swap at least 2GB
- Close other memory-heavy processes before building
- Expected RAM usage: ~3-4GB peak (with 800m JVM, system has 9GB total)
