package com.devid.musly

import android.app.Application
import android.os.Looper
import android.util.Log
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import java.lang.ref.WeakReference

/**
 * Custom Application class declared in AndroidManifest.xml via
 * `android:name=".MuslyApplication"`.
 *
 * Android requires this class to exist at process startup.
 * Most custom platform-channel
 * plugin registration (DolbyAtmos, Bluetooth AVRCP, Samsung integration,
 * Lyrics, Pitch, AndroidSystem) happens in [MainActivity.configureFlutterEngine]
 * where the FlutterEngine instance is available. The exception is the
 * audio_service wake lock channel, attached here because audio_service can
 * create its engine with no activity.
 */
class MuslyApplication : Application() {

    private var wakeLockEngine = WeakReference<FlutterEngine>(null)

    override fun onCreate() {
        super.onCreate()
        Log.d("MuslyApplication", "Application started")

        // audio_service creates the engine itself when a media key or Android
        // Auto starts it with no activity, and MainActivity.configureFlutterEngine
        // never runs for that engine. Attach the wake lock channel to whichever
        // engine audio_service is using, once it exists.
        Looper.myQueue().addIdleHandler {
            val engine = FlutterEngineCache.getInstance()
                .get(AudioServicePlugin.getFlutterEngineId())
            if (engine != null && engine !== wakeLockEngine.get()) {
                AudioServiceWakeLock.register(engine)
                wakeLockEngine = WeakReference(engine)
            }
            true
        }
    }
}

