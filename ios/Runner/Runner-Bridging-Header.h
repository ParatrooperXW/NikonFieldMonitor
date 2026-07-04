// Runner-Bridging-Header.h
//
// Bridging header for Swift <-> Objective-C interop in the Runner target.
//
// This project is pure-Swift: AppDelegate.swift, RenderPlugin.swift,
// LiveViewRenderer.swift, ShaderProgram.swift, and UsbPtpPlugin.swift all
// import their dependencies (Flutter, Metal, CoreVideo, ImageIO, UIKit)
// directly from system frameworks — no Objective-C sources are compiled
// into Runner. The .metal shader files are compiled into default.metallib
// by Xcode's Metal compiler (Run Script build phase OR the default
// "Compile Sources" phase for .metal files) and loaded at runtime via
// device.makeDefaultLibrary(), so they don't go through the bridging header
// either.
//
// Leave this file empty unless you add Objective-C sources to Runner/.
// (The GeneratedPluginRegistrant.h/.m produced by `flutter pub get` is
// precompiled into the Runner target via Xcode's ObjC compiler and does
// not require any bridging-header import here — AppDelegate.swift calls
// GeneratedPluginRegistrant.register(with:) via Swift's ObjC interop, which
// is available without a bridging header for ObjC classes declared in the
// same module.)

#ifndef Runner_Bridging_Header_h
#define Runner_Bridging_Header_h

// Intentionally empty.

#endif /* Runner_Bridging_Header_h */
