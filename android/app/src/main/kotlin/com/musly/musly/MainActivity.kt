package com.devid.musly

import android.content.Context
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {

    /**
     * Attach to the process-wide engine instead of creating a private one, so
     * the UI and a headless engine started by [MusicService] can never both be
     * running the app (two PlayerProviders, two audio players). If Musly was
     * woken by a head unit first, this hands the already-running instance its
     * UI; otherwise it creates the engine as usual.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        MuslyEngine.getOrCreate(context)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // No-op when the engine came from MuslyEngine.getOrCreate above; needed
        // for the case where Flutter handed us an engine of its own.
        MuslyEngine.registerPlugins(flutterEngine, this)
    }
}
