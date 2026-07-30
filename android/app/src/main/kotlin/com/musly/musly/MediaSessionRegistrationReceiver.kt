package com.devid.musly

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Re-registers Musly's MediaSession after the events that wipe it, so a car
 * head unit's PLAY still reaches us.
 *
 * The framework routes a media button to the last known media button receiver.
 * That record is gone after a reboot, and an app that has just been updated sits
 * in the package "stopped" state with all of its PendingIntents cancelled
 * (Android 15+ cancels them explicitly). Until something in Musly runs and
 * creates a MediaSession again, the head unit talks to nobody — so before this
 * receiver existed, every reboot and every Obtainium update left the car dead
 * until the app was next opened by hand.
 *
 * The three actions below are the only ones the platform delivers in those
 * situations:
 *  - ACTION_BOOT_COMPLETED / ACTION_LOCKED_BOOT_COMPLETED after a restart
 *  - ACTION_MY_PACKAGE_REPLACED to an app that has just been updated, which is
 *    also what lifts it back out of the stopped state
 *
 * All three are on the platform's list of broadcasts that may start a foreground
 * service from the background, which is what makes the registration below legal.
 * MusicService registers the session and then stands down immediately
 * (see ACTION_REGISTER_SESSION) — nothing is left running and no notification
 * remains, because the framework remembers the media button receiver even after
 * the session and the whole process are gone.
 */
class MediaSessionRegistrationReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "MediaSessionReg"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null) return

        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                Log.d(TAG, "Re-registering media session after ${intent.action}")
                try {
                    val service = Intent(context, MusicService::class.java).apply {
                        action = MusicService.ACTION_REGISTER_SESSION
                    }
                    ContextCompat.startForegroundService(context, service)
                } catch (e: Exception) {
                    // Never crash a boot receiver. If the FGS start is refused
                    // we simply stay unregistered until the app is next opened,
                    // which is the old behaviour.
                    Log.w(TAG, "Could not start MusicService to register: ${e.message}")
                }
            }

            else -> Log.d(TAG, "Ignoring ${intent?.action}")
        }
    }
}
