# Local APK Build Instructions

## Prerequisites
- Flutter SDK at `$HOME/flutter-sdk`
- Android SDK at `$HOME/android-sdk`
- Java 17+ (last verified with Java 21 from mise: `$HOME/.local/share/mise/installs/java/21.0`)
- Python 3.11 on PATH (for Chaquopy/yt-dlp). This box has no system python; a standalone
  build is unpacked at `$HOME/python`
- Release keystore at `~/release.keystore`, with `android/key.properties` pointing to it
  (gitignored; copy it into any worktree you build from)

## Memory-Conscious Build
This build is **memory-intensive** because of:
- Flutter compilation
- Gradle with Android SDK processing, plus R8 for release
- The Kotlin compiler
- Chaquopy (Python) building native libs for 3 ABIs (arm64-v8a, armeabi-v7a, x86_64), and the
  yt-dlp pip install

**Run one JVM, not two.** By default Kotlin compiles in a separate daemon JVM. Under a memory
cap that daemon fails to start ("Could not connect to Kotlin compile daemon"). Kotlin then
silently falls back to compiling inside the Gradle daemon, which by then is squeezed by the
same caps. So run Kotlin in-process on purpose, and size the Gradle daemon to hold it:

```bash
export _JAVA_OPTIONS="-Xmx1536m -XX:MaxMetaspaceSize=512m"
flutter build apk --release -Pkotlin.compiler.execution.strategy=in-process
```

- `-Pkotlin.compiler.execution.strategy=in-process` has to be a Gradle **project** property
  (`-P`). Valid values are only `daemon` and `in-process`; see
  https://kotlinlang.org/docs/compiler-execution-strategy.html
- `_JAVA_OPTIONS` applies to every JVM and overrides `org.gradle.jvmargs` in
  `android/gradle.properties`. Setting it is how the heap stays capped without editing the
  tracked file.

### Do not use the old recipe
Earlier versions of this file said to use
`GRADLE_OPTS="... -Dkotlin.compiler.execution.strategy=direct"` with
`_JAVA_OPTIONS="-Xmx1200m -XX:MaxMetaspaceSize=256m"`. That combination does not work:
- `GRADLE_OPTS` only reaches the small Gradle *client* JVM, never the daemon that compiles.
- `direct` is not a valid strategy.
- So the Kotlin daemon was still used. It failed to connect and fell back to in-process
  compilation inside a Gradle daemon capped at 256m metaspace.

On 2026-09-25 (Kotlin 2.2.20, AGP/Gradle 8.14) this GC-thrashed for 20+ minutes with no log
output and then hit OutOfMemoryError. With the flags above the same build took about
2 minutes.

## Build Command
```bash
export PATH="$HOME/flutter-sdk/bin:$HOME/python/bin:$PATH"
export FLUTTER_SUPPRESS_ANALYTICS=1
export ANDROID_SDK_ROOT="$HOME/android-sdk"
export ANDROID_HOME="$HOME/android-sdk"
export JAVA_HOME="$HOME/.local/share/mise/installs/java/21.0"
export PATH="$JAVA_HOME/bin:$PATH"
export _JAVA_OPTIONS="-Xmx1536m -XX:MaxMetaspaceSize=512m"

flutter clean
flutter pub get
flutter build apk --release -Pkotlin.compiler.execution.strategy=in-process
```

## If the build goes quiet
If the log stops advancing for several minutes, check whether the Gradle daemon is thrashing
before you wait any longer:

```bash
jstat -gcutil $(pgrep -f GradleDaemon | head -1)
```

If `FGC` (full GC count) climbs every few seconds while `O` (old gen) sits near 100, it will not
recover. Kill it, fix the flags, and rebuild. A daemon that died of OOM leaves a
`android/java_pid*.hprof` heap dump of about 1 GB (from `-XX:+HeapDumpOnOutOfMemoryError` in
`gradle.properties`). Delete it.

## Post-Build Verification
`apksigner` needs Java on PATH; with none it prints nothing at all.

```bash
~/android-sdk/build-tools/35.0.0/apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
# Should show: CN=Musly (not Android Debug), cert SHA-256 152eda11…76dc
~/android-sdk/build-tools/35.0.0/aapt2 dump badging build/app/outputs/flutter-apk/app-release.apk | head -1
# versionCode must be higher than the previous tbrackbill release, or it will not install over it
```

## Versioning
- Tags are `vX.Y.Z-tbrackbill`, never a bare `vX.Y.Z`, so they cannot collide with an upstream
  release tag.
- Bump `version:` in `pubspec.yaml` (`X.Y.Z+N`, with N sequential) **only on the release
  branch** (`release/vX.Y.Z-tbrackbill`). Keep fix branches free of version bumps so they rebase
  cleanly onto upstream and can be sent as PRs unchanged.

## Upload to Release
```bash
git tag -a vX.Y.Z-tbrackbill -m "..." && git push origin release/vX.Y.Z-tbrackbill vX.Y.Z-tbrackbill
gh release create vX.Y.Z-tbrackbill build/app/outputs/flutter-apk/app-release.apk \
  --repo tbrackbill/Musly --verify-tag --title "..." --notes-file notes.md
```

## Notes
- Keep swap at least 2GB (zram 4G here).
- Close other memory-heavy processes before building, including a `flutter test` run.
- Observed peak with the flags above: about 2.7 GB RSS for the Gradle daemon, with at least
  3.7 GB still available on a 9 GB box.
