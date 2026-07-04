package com.nikonfieldmonitor.app

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.nikonfieldmonitor.render.RenderPlugin
import com.nikonfieldmonitor.usb.UsbPtpPlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        try {
            val ctx = this
            flutterEngine.plugins.add(UsbPtpPlugin(ctx))
            flutterEngine.plugins.add(RenderPlugin(ctx))
        } catch (e: Exception) {
            Log.e("MainActivity", "Failed to register plugins", e)
        }
    }
}
