// UsbPtpPlugin.swift — iOS stub of the "nikon_field_monitor/usb_ptp" channel.
//
// Counterpart of android/app/src/main/kotlin/com/nikonfieldmonitor/usb/UsbPtpPlugin.kt
// (which wraps android.hardware.usb for PTP-over-USB bulk transfers).
//
// iOS does NOT expose USB-C camera access to third-party apps without MFi
// enrollment + the ExternalAccessory framework — and even then only
// MFi-certified cameras would enumerate (Nikon Z-series bodies are not
// MFi-certified for this app's case). Therefore every USB method on iOS
// returns a FlutterError with code "platformVersion" / message
// "not-supported", so the Dart side (lib/native_bridge/usb_ptp_bridge.dart)
// can catch the PlatformException and present an "unsupported on iOS" UI.
//
// The single exception is `getPlatformVersion`, which returns the iOS version
// string so the Dart side can detect "channel present but USB unavailable"
// at runtime (parity with the Android stub that returns
// Build.VERSION.RELEASE).
//
// Channel: "nikon_field_monitor/usb_ptp"
//   getPlatformVersion()                      -> String (e.g. "17.4")
//   hasUsbHost()                              -> throws platformVersion/not-supported
//   listUsbDevices()                          -> throws platformVersion/not-supported
//   requestPermission(deviceId)               -> throws platformVersion/not-supported
//   open(deviceId)                            -> throws platformVersion/not-supported
//   close(sessionHandle)                      -> throws platformVersion/not-supported
//   operate(sessionHandle, opCode, params, outData?, expectData)
//                                            -> throws platformVersion/not-supported
//
// EventChannel "nikon_field_monitor/usb_ptp/events":
//   never emits (no USB device attach/detach/ptpEvent on iOS). The stream is
//   kept open but silent so Dart's startEventStream() doesn't observe a
//   cancelled stream.
//
// References:
//   - ExternalAccessory.framework (MFi required for USB-C camera enumeration)
//   - lib/ptp/nikon_opcodes.dart (Nikon PTP opcodes used by `operate`; on iOS
//     we never reach the opcode layer, so the gphoto2 camlibs/ptp2/nikon.h
//     opcode table cross-check does not apply here).

import Foundation
import Flutter
import UIKit

final class UsbPtpPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var eventSink: FlutterEventSink?

    // MARK: - FlutterPlugin

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = UsbPtpPlugin()

        let mc = FlutterMethodChannel(name: "nikon_field_monitor/usb_ptp",
                                      binaryMessenger: registrar.messenger())
        mc.setMethodCallHandler { [weak plugin] call, result in
            plugin?.handle(call, result: result)
        }

        let ec = FlutterEventChannel(name: "nikon_field_monitor/usb_ptp/events",
                                     binaryMessenger: registrar.messenger())
        ec.setStreamHandler(plugin)

        registrar.publish(plugin)
    }

    // MARK: - Method dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            // Equivalent to the Android stub returning Build.VERSION.RELEASE.
            // Used by Dart to detect "channel present but USB unavailable".
            result(UIDevice.current.systemVersion)

        case "hasUsbHost",
             "listUsbDevices",
             "requestPermission",
             "open",
             "close",
             "operate":
            // All USB methods are unsupported on iOS — USB-C camera access
            // requires MFi + ExternalAccessory framework, and Nikon Z-series
            // bodies are not MFi-certified for third-party apps.
            //
            // Note: `operate` carries Nikon PTP opcodes (see
            // lib/ptp/nikon_opcodes.dart); on iOS we never reach the opcode
            // transport layer, so the gphoto2 camlibs/ptp2/nikon.h
            // cross-check that the Android file carries does not apply here.
            result(FlutterError(
                code: "platformVersion",
                message: "not-supported: USB-C PTP camera access requires MFi + ExternalAccessory framework on iOS",
                details: nil))

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        // No USB events ever fire on iOS — keep the sink open but silent so
        // Dart's startEventStream() doesn't see a cancelled stream.
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
