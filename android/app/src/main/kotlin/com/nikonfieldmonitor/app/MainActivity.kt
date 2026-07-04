package com.nikonfieldmonitor.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.nikonfieldmonitor.render.RenderPlugin
import com.nikonfieldmonitor.usb.UsbPtpPlugin

/**
 * Main Flutter activity.
 *
 * Registers our two MethodChannel plugins:
 *  - RenderPlugin  ("nikon_field_monitor/render")     -> OpenGL ES LiveView texture + GPU pipeline
 *  - UsbPtpPlugin  ("nikon_field_monitor/usb_ptp")    -> Android USB Host PTP transport
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(UsbPtpPlugin(context))
        flutterEngine.plugins.add(RenderPlugin(context))
    }
}
