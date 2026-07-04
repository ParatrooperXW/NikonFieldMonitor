// LiveView service — drives the GetLiveViewImg polling loop and pushes JPEG
// frames to the native renderer through [RenderBridge].
//
// The loop runs on the Dart side using async* + Stream; CPU-heavy JPEG decode
// happens on the native side (libjpeg-turbo on Android, vImage on iOS) to keep
// the UI isolate responsive. If a future build needs Isolate decoding in Dart,
// [pushRgbaFrame] is the entry point for that path.
//
// Telemetry (fps/latency) is forwarded to the UI from [RenderBridge.frameStats].
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models/camera_state.dart';
import '../native_bridge/native_render_bridge.dart';
import '../ptp/liveview_parser.dart';
import '../ptp/ptp_ip_client.dart';
import 'connection_service.dart';

class LiveViewService {
  LiveViewService({required this.connection, required this.bridge});

  final ConnectionService connection;
  final RenderBridge bridge;

  int? _textureId;
  Timer? _pollTimer;
  bool _running = false;
  int _frameCount = 0;
  DateTime? _lastTick;
  double _fps = 0;
  int _latencyMs = 0;

  final _telemetryController = StreamController<LiveViewTelemetry>.broadcast();
  Stream<LiveViewTelemetry> get telemetry => _telemetryController.stream;

  int? get textureId => _textureId;

  Future<int> ensureTexture() async {
    if (_textureId != null) return _textureId!;
    _textureId = await bridge.createTexture();
    bridge.startListening();
    return _textureId!;
  }

  Future<void> releaseTexture() async {
    final id = _textureId;
    if (id == null) return;
    await bridge.releaseTexture(id);
    _textureId = null;
  }

  /// Start the LiveView polling loop.
  ///
  /// [interval] defaults to ~33ms (≈30 fps). Nikon cameras typically throttle
  /// GetLiveViewImg themselves, so a tighter interval just consumes CPU.
  Future<void> start({Duration interval = const Duration(milliseconds: 33)}) async {
    if (_running) return;
    await ensureTexture();
    final startRes = await connection.startLiveView();
    if (!startRes.isOk && startRes.code != 0x200A /* already on */) {
      throw PtpException('StartLiveView failed: 0x${startRes.code.toRadixString(16)}');
    }
    _running = true;
    _frameCount = 0;
    _lastTick = DateTime.now();
    _pollTimer = Timer.periodic(interval, (_) => _tick());
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _running = false;
    try {
      await connection.endLiveView();
    } on Exception {
      // ignore: camera may already have closed
    }
  }

  Future<void> _tick() async {
    if (!_running || _textureId == null) return;
    final t0 = DateTime.now();
    try {
      final blob = await connection.getLiveViewImg();
      final frame = parseLiveViewImg(blob);
      await bridge.pushJpegFrame(_textureId!, frame.jpeg);
      _frameCount++;
      final now = DateTime.now();
      final dt = now.difference(_lastTick!);
      if (dt.inMilliseconds > 0) {
        _fps = _fps * 0.8 + (1000.0 / dt.inMilliseconds) * 0.2;
      }
      _latencyMs = now.difference(t0).inMilliseconds;
      _lastTick = now;
      _telemetryController.add(LiveViewTelemetry(
        fps: _fps,
        latencyMs: _latencyMs,
        frameCount: _frameCount,
        lastFrameAt: now,
      ));
    } on LiveViewNotReadyException {
      // camera still spinning up; next tick will retry
    } on SocketException catch (e) {
      _telemetryController.addError(e);
      await stop();
    } on PtpException catch (e) {
      _telemetryController.addError(e);
    }
  }

  void dispose() {
    _pollTimer?.cancel();
    _telemetryController.close();
  }
}
