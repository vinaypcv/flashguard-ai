package com.sandisk.flashguard.flashguard_ai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sandisk.flashguard/volume")
            .setMethodCallHandler { call, result ->
                if (call.method == "getVolumeStats") {
                    // SAF content URIs are document streams, not mount paths. A future
                    // adapter must obtain a persisted URI grant and resolve its volume.
                    result.error("VOLUME_API_NOT_WIRED", "Android SAF volume adapter is pending", null)
                } else {
                    result.notImplemented()
                }
            }
    }
}
