package com.devid.musly

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Debug-build-only test hook. Lets `tools/bt_headunit_test.sh` drive the
 * Bluetooth resume-on-connect path from adb with no car and no A2DP hardware:
 *
 *   adb shell am broadcast -n com.devid.musly/.DebugBluetoothReceiver \
 *       -a com.devid.musly.DEBUG_BT_CONNECT
 *   adb shell am broadcast -n com.devid.musly/.DebugBluetoothReceiver \
 *       -a com.devid.musly.DEBUG_BT_STATUS
 *
 * The explicit component is required: an implicit broadcast cannot start a
 * manifest receiver on Android 8+.
 *
 * This receiver is declared only in src/debug/AndroidManifest.xml, so it does
 * not exist in a release APK. [BluetoothMediaHelper] additionally refuses the
 * calls unless the running APK is debuggable.
 *
 * Being a manifest receiver, it starts the app process if it is not running —
 * which is itself the diagnostic: a cold process has no attached Flutter
 * engine, so [BluetoothMediaHelper.activeInstance] is null and the log says so.
 * That is exactly the state the app is in when the real ACL_CONNECTED broadcast
 * arrives with Musly closed, and the reason nothing resumes.
 */
class DebugBluetoothReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "DebugBtReceiver"
        const val ACTION_CONNECT = "com.devid.musly.DEBUG_BT_CONNECT"
        const val ACTION_STATUS = "com.devid.musly.DEBUG_BT_STATUS"

        private const val DEFAULT_ADDRESS = "00:11:22:33:44:55"
        private const val DEFAULT_NAME = "Simulated Head Unit"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        val helper = BluetoothMediaHelper.activeInstance

        if (helper == null) {
            // The BT receiver is registered by BluetoothAvrcpPlugin, which only
            // attaches to MainActivity's FlutterEngine. No engine => nothing in
            // this process is listening for Bluetooth connects.
            Log.w(TAG, "DEBUG_BT result=NO_HELPER " +
                "(no Flutter engine attached; a real BT connect would also reach nobody)")
            return
        }

        when (intent?.action) {
            ACTION_CONNECT -> {
                val address = intent.getStringExtra("address") ?: DEFAULT_ADDRESS
                val name = intent.getStringExtra("name") ?: DEFAULT_NAME
                // Default true: the point of the hook is to exercise the resume
                // path, and a synthetic device is never in the A2DP proxy list.
                val forceActive = !intent.hasExtra("a2dp") ||
                    intent.getBooleanExtra("a2dp", true)

                val ok = helper.debugSimulateDeviceConnected(address, name, forceActive)
                Log.i(TAG, "DEBUG_BT result=${if (ok) "DISPATCHED" else "REFUSED_NOT_DEBUGGABLE"} " +
                    "device=$name a2dp=$forceActive")
            }

            ACTION_STATUS -> {
                Log.i(TAG, "DEBUG_BT result=STATUS ${helper.debugStateSummary()}")
            }

            else -> Log.w(TAG, "DEBUG_BT result=UNKNOWN_ACTION action=${intent?.action}")
        }
    }
}
