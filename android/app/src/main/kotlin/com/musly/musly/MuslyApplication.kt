package com.devid.musly

import android.app.Application
import android.content.Context
import android.os.PowerManager
import android.util.Log

/**
 * Custom Application class declared in AndroidManifest.xml via
 * `android:name=".MuslyApplication"`.
 *
 * Android requires this class to exist at process startup.
 * All custom platform-channel
 * plugin registration (DolbyAtmos, Bluetooth AVRCP, Samsung integration,
 * Lyrics, Pitch, AndroidSystem) happens in [MainActivity.configureFlutterEngine]
 * where the FlutterEngine instance is available. The one thing done here is
 * holding the CPU awake while the process starts; see [holdCpuWhileStarting].
 */
class MuslyApplication : Application() {

    /** Held in a field: a WakeLock that is garbage collected is released. */
    private var startupWakeLock: PowerManager.WakeLock? = null

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        holdCpuWhileStarting()
    }

    override fun onCreate() {
        super.onCreate()
        Log.d("MuslyApplication", "Application started")
    }

    /**
     * A car or headset button that starts the process arrives with no wake lock
     * held: Bluetooth AVRCP and AudioManager.dispatchMediaKeyEvent ask the media
     * session service for none. With the screen off, the CPU then slept between
     * the steps of starting audio_service and the Flutter engine, and playback
     * began close to a minute after the press. audio_service takes its own wake
     * lock once playback starts; this covers starting up until then, from
     * before the content providers and the media button receiver run. The
     * timeout bounds it, since it is taken on every process start.
     *
     * In deep Doze, Android honours it only while the media button's temporary
     * allowlist lasts (10 s by default, Android 12 and later), or once
     * audio_service is in the foreground. On Android 11 and earlier there is no
     * such allowlist, so in deep Doze it helps only after that point.
     */
    private fun holdCpuWhileStarting() {
        try {
            val power = getSystemService(PowerManager::class.java) ?: return
            startupWakeLock =
                power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "musly:cold-start").apply {
                    setReferenceCounted(false)
                    acquire(COLD_START_WAKE_LOCK_MS)
                }
        } catch (e: RuntimeException) {
            Log.w("MuslyApplication", "Could not hold a wake lock while starting", e)
        }
    }

    private companion object {
        const val COLD_START_WAKE_LOCK_MS = 30_000L
    }
}

