package com.devid.musly

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * The app's single FlutterEngine, shared by [MainActivity] and [MusicService].
 *
 * A car head unit's PLAY arrives when Musly's process is dead. Android refuses
 * background activity launches ("Background activity launch blocked", BAL), so
 * MusicService cannot bring Dart up by starting MainActivity. Instead it starts
 * this engine headlessly: main() runs, PlayerProvider is constructed and
 * restores the persisted queue, AndroidAutoPlugin flushes the pending "play",
 * and audio starts without any UI ever being shown.
 *
 * There must only ever be ONE engine in the process. The platform plugins below
 * are Kotlin objects holding a single channel each, and a second engine would
 * also mean a second PlayerProvider driving a second just_audio instance — two
 * players fighting over one audio focus. MainActivity therefore attaches to this
 * cached engine instead of creating its own.
 */
object MuslyEngine {
    private const val TAG = "MuslyEngine"

    const val ENGINE_ID = "musly_shared_engine"

    /**
     * Returns the shared engine, creating and starting Dart if it does not exist
     * yet. Must be called on the main thread.
     */
    fun getOrCreate(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }

        Log.d(TAG, "Creating shared FlutterEngine (headless if no activity)")
        val appContext = context.applicationContext
        // Auto-registers the pub plugins from GeneratedPluginRegistrant; our own
        // platform channels are added below.
        val engine = FlutterEngine(appContext)
        registerPlugins(engine, appContext)

        if (!engine.dartExecutor.isExecutingDart) {
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
        }

        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    /** Engine whose channels are already wired, so we never register twice. */
    private var registeredFor: java.lang.ref.WeakReference<FlutterEngine>? = null

    /**
     * Musly's own platform channels. Idempotent per engine, which matters:
     * [engine.plugins.add] ignores an already-attached plugin class, but the
     * `registerWith` helpers below do not — each call builds a fresh plugin
     * instance and replaces the channel handler. Registering twice would swap
     * the lyrics EventChannel's stream handler out from under a Dart
     * subscription that had already attached to the first one, silently killing
     * lock-screen lyrics.
     */
    fun registerPlugins(engine: FlutterEngine, context: Context) {
        if (registeredFor?.get() === engine) return
        registeredFor = java.lang.ref.WeakReference(engine)

        engine.plugins.add(AndroidAutoPlugin)
        engine.plugins.add(AndroidSystemPlugin)
        engine.plugins.add(BluetoothAvrcpPlugin)
        engine.plugins.add(SamsungIntegrationPlugin)
        LyricsPlugin.registerWith(engine)
        PitchPlugin.registerWith(engine)
        DolbyAtmosPlugin.registerWith(engine, context)
    }
}
