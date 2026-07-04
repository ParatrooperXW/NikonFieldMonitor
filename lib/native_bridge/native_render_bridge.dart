// Native render bridge — the MethodChannel + Texture surface contract between
// Dart and the per-platform native renderer (Kotlin/OpenGL ES on Android,
// Swift/Metal on iOS).
//
// Contract (channel: "nikon_field_monitor/render"):
//
//   Dart -> Native (MethodChannel):
//     createTexture()                              -> {textureId: int}
//     releaseTexture(int textureId)                -> null
//     pushJpegFrame(int textureId, Uint8List jpeg) -> null
//     pushRgbaFrame(int textureId, Uint8List rgba, int w, int h) -> null
//     updateAssistSettings(int textureId, Map settings) -> null
//     uploadLut(String lutId, Uint8List rgba, int size) -> null
//     removeLut(String lutId)                      -> null
//     setLutActive(int textureId, String? lutId)   -> null
//
//   Native -> Dart (EventChannel "nikon_field_monitor/render/events"):
//     {event: "frameStats", fps: double, latencyMs: int, width: int, height: int}
//     {event: "renderError", message: String}
//
// On Android the native side uses SurfaceTexture + GLSurfaceView-equivalent
// EGL context; on iOS it uses CVMetalTextureCache + MTKView-less rendering.
//
// References:
//   - Flutter Texture widget: flutter.dev/docs/development/platform-integration
//   - remoteyourcam-usb LiveViewTextureRenderer (Android GLSurfaceView pattern)
//   - GPUImage 3 / MetalPetal (iOS Metal shader pipelines)
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class RenderBridge {
  RenderBridge() {
    _methodChannel.setMethodCallHandler(_handleNativeCall);
  }

  static const MethodChannel _methodChannel =
      MethodChannel('nikon_field_monitor/render');
  static const EventChannel _eventChannel =
      EventChannel('nikon_field_monitor/render/events');

  StreamSubscription<dynamic>? _eventSub;
  final _frameStatsController = StreamController<FrameStats>.broadcast();
  final _renderErrorController = StreamController<String>.broadcast();

  Stream<FrameStats> get frameStats => _frameStatsController.stream;
  Stream<String> get renderErrors => _renderErrorController.stream;

  /// Allocate a Flutter texture on the native side. Returns its textureId.
  Future<int> createTexture() async {
    try {
      final res = await _methodChannel.invokeMethod<int>('createTexture');
      if (res == null) {
        throw PlatformException(
          code: 'RENDER_INIT',
          message: 'createTexture returned null',
        );
      }
      return res;
    } on PlatformException {
      rethrow;
    } on MissingPluginException catch (e) {
      throw PlatformException(
        code: 'RENDER_INIT',
        message: 'Render plugin not available: $e',
      );
    } catch (e) {
      throw PlatformException(
        code: 'RENDER_INIT',
        message: 'createTexture failed: $e',
      );
    }
  }

  Future<void> releaseTexture(int textureId) =>
      _methodChannel.invokeMethod<void>('releaseTexture', {'textureId': textureId});

  /// Push a JPEG-encoded LiveView frame to the native decoder/renderer.
  Future<void> pushJpegFrame(int textureId, Uint8List jpeg) =>
      _methodChannel.invokeMethod<void>('pushJpegFrame', {
        'textureId': textureId,
        'jpeg': jpeg,
      });

  /// Push a pre-decoded RGBA buffer (used when Dart Isolate decoded it).
  Future<void> pushRgbaFrame(int textureId, Uint8List rgba, int width, int height) =>
      _methodChannel.invokeMethod<void>('pushRgbaFrame', {
        'textureId': textureId,
        'rgba': rgba,
        'width': width,
        'height': height,
      });

  /// Update GPU post-processing pipeline configuration (peaking/zebra/etc.).
  Future<void> updateAssistSettings(int textureId, Map<String, Object?> settings) =>
      _methodChannel.invokeMethod<void>('updateAssistSettings', {
        'textureId': textureId,
        'settings': settings,
      });

  /// Upload a 3D LUT (RGBA packed 2D texture) to the GPU.
  Future<void> uploadLut(String lutId, Uint8List rgba, int size) =>
      _methodChannel.invokeMethod<void>('uploadLut', {
        'lutId': lutId,
        'rgba': rgba,
        'size': size,
      });

  Future<void> removeLut(String lutId) =>
      _methodChannel.invokeMethod<void>('removeLut', {'lutId': lutId});

  /// Bind the active LUT to a texture (null = LUT off).
  Future<void> setLutActive(int textureId, String? lutId) =>
      _methodChannel.invokeMethod<void>('setLutActive', {
        'textureId': textureId,
        'lutId': lutId,
      });

  void startListening() {
    _eventSub?.cancel();
    _eventSub = _eventChannel.receiveBroadcastStream().listen(_onEvent, onError: (Object e) {
      _renderErrorController.add(e.toString());
    });
  }

  void stopListening() {
    _eventSub?.cancel();
    _eventSub = null;
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    final type = event['event'];
    switch (type) {
      case 'frameStats':
        _frameStatsController.add(FrameStats(
          fps: (event['fps'] as num?)?.toDouble() ?? 0,
          latencyMs: (event['latencyMs'] as num?)?.toInt() ?? 0,
          width: (event['width'] as num?)?.toInt() ?? 0,
          height: (event['height'] as num?)?.toInt() ?? 0,
        ));
      case 'renderError':
        _renderErrorController.add(event['message'] as String? ?? 'unknown');
      default:
        break;
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    // Reserved for any callbacks native side might invoke on Dart.
    return null;
  }

  void dispose() {
    stopListening();
    _frameStatsController.close();
    _renderErrorController.close();
  }
}

class FrameStats {
  const FrameStats({
    required this.fps,
    required this.latencyMs,
    required this.width,
    required this.height,
  });
  final double fps;
  final int latencyMs;
  final int width;
  final int height;
}
