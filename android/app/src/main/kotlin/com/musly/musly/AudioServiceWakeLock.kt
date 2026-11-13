package com.devid.musly

import android.util.Log
import com.ryanheise.audioservice.AudioService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Lets the Dart side release audio_service's partial wake lock after a long
 * pause. The plugin holds that lock from play until its service is destroyed
 * (Musly keeps androidStopForegroundOnPause off so playback can restart from
 * the background) and re-acquires it itself on the next play, but offers no
 * public way to let go of it in between, hence reflection. The members used
 * are kept in proguard-rules.pro.
 */
object AudioServiceWakeLock {
    private const val CHANNEL = "com.devid.musly/audio_service"

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "releaseWakeLock") {
                try {
                    result.success(release())
                } catch (e: Exception) {
                    Log.w("AudioServiceWakeLock", "Could not release audio_service's wake lock", e)
                    result.error("RELEASE_ERROR", e.toString(), null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    /** Returns false when there is no service or it is playing. */
    private fun release(): Boolean {
        val cls = AudioService::class.java
        val service = cls.getDeclaredField("instance")
            .apply { isAccessible = true }
            .get(null) as AudioService? ?: return false
        if (service.isPlaying) return false
        cls.getDeclaredMethod("releaseWakeLock")
            .apply { isAccessible = true }
            .invoke(service)
        return true
    }
}
