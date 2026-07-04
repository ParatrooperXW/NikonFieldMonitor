// AppDelegate.swift — iOS application entry point.
//
// Counterpart of android/app/src/main/kotlin/com/nikonfieldmonitor/app/MainActivity.kt.
// Where the Android MainActivity adds UsbPtpPlugin + RenderPlugin to the
// FlutterEngine, here we register both plugins with the engine's registrar.
//
// Responsibilities:
//   1. Register the GeneratedPluginRegistrant (third-party pub plugins from
//      pubspec.yaml: permission_handler, network_info_plus, wakelock_plus,
//      path_provider, file_picker, ...).
//   2. Manually register our two custom plugins (they live in Runner/, not in
//      a pub package, so GeneratedPluginRegistrant does not know about them):
//        - RenderPlugin  ("nikon_field_monitor/render" + "/render/events")
//        - UsbPtpPlugin   ("nikon_field_monitor/usb_ptp" + "/usb_ptp/events")
//
// LiveView keep-awake:
//   RenderPlugin.register(with:) installs an `onLiveViewActiveChanged` closure
//   that flips `UIApplication.shared.isIdleTimerDisabled` whenever the count
//   of active LiveView textures transitions between zero and non-zero. This
//   mirrors Android's use of FLAG_KEEP_SCREEN_ON in RenderPlugin.kt. No
//   additional logic is required here.

import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        // 1) Third-party pub plugins. GeneratedPluginRegistrant is produced by
        //    `flutter pub get` and lives in
        //    Runner/GeneratedPluginRegistrant.h/.m. Safe to call unconditionally
        //    (it's a no-op if there are no plugin packages).
        GeneratedPluginRegistrant.register(with: self)

        // 2) Our two custom plugins. registrar(forPlugin:) returns an optional;
        //    FlutterAppDelegate always provides one, so force-unwrap is safe.
        //
        //    RenderPlugin: registers the Metal-backed LiveView texture surface.
        //      Its onLiveViewActiveChanged closure (set inside register(with:))
        //      toggles UIApplication.shared.isIdleTimerDisabled on the main
        //      thread so the screen stays awake while a feed is running.
        //
        //    UsbPtpPlugin: iOS stub. getPlatformVersion returns the iOS version
        //      string; every USB method (hasUsbHost, listUsbDevices,
        //      requestPermission, open, close, operate) returns a FlutterError
        //      with code "platformVersion" / message "not-supported" because
        //      iOS USB-C camera access requires MFi + the ExternalAccessory
        //      framework (and Nikon Z-series bodies are not MFi-certified for
        //      third-party apps). The EventChannel is silent.
        RenderPlugin.register(with: self.registrar(forPlugin: "RenderPlugin")!)
        UsbPtpPlugin.register(with: self.registrar(forPlugin: "UsbPtpPlugin")!)

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
