// Connection service — owns the active camera transport (Wi-Fi PTP/IP or USB)
// and exposes high-level operations (capture, start/stop record, set ISO etc.).
//
// Responsibilities:
//   * Connect via [PtpIpClient] (Wi-Fi) or [UsbPtpBridge] (Android USB OTG).
//   * Read DeviceInfo + device properties to populate [CameraProperties].
//   * Provide a single [operate] entry point that fans out to the right transport.
//   * Auto-reconnect on socket close (best-effort, debounced).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models/camera_state.dart';
import '../native_bridge/usb_ptp_bridge.dart';
import '../ptp/nikon_opcodes.dart';
import '../ptp/ptp_ip_client.dart';

/// Result of an operation, transport-agnostic.
class OpResult {
  const OpResult({required this.code, this.params = const [], this.data});
  final int code; // PtpResponse.*
  final List<int> params;
  final Uint8List? data;
  bool get isOk => code == PtpResponse.ok;
}

/// The active transport handle.
sealed class ActiveTransport {}

class WifiTransport extends ActiveTransport {
  WifiTransport(this.client);
  final PtpIpClient client;
}

class UsbTransport extends ActiveTransport {
  UsbTransport(this.session);
  final UsbPtpSession session;
}

class ConnectionService {
  ConnectionService({required this.usb});

  final UsbPtpBridge usb;
  ActiveTransport? _transport;
  CameraTransport _kind = CameraTransport.none;
  Timer? _reconnectTimer;
  String _lastHost = '';
  int _lastPort = 15740;
  String? _lastUsbDeviceId;
  bool _autoReconnect = true;

  ActiveTransport? get transport => _transport;
  CameraTransport get kind => _kind;
  bool get isConnected => _transport != null;

  /// Connect over Wi-Fi PTP/IP.
  Future<void> connectWifi(String host, [int port = 15740]) async {
    _lastHost = host;
    _lastPort = port;
    _kind = CameraTransport.wifi;
    final client = PtpIpClient();
    await client.connect(InternetAddress(host), port);
    _transport = WifiTransport(client);
  }

  /// Connect over Android USB OTG.
  Future<UsbPtpSession> connectUsb(String deviceId) async {
    _lastUsbDeviceId = deviceId;
    _kind = CameraTransport.usb;
    final ok = await usb.requestPermission(deviceId);
    if (!ok) {
      throw PtpException('USB permission denied for $deviceId');
    }
    final session = await usb.open(deviceId);
    _transport = UsbTransport(session);
    return session;
  }

  Future<void> disconnect() async {
    _autoReconnect = false;
    _reconnectTimer?.cancel();
    final t = _transport;
    _transport = null;
    switch (t) {
      case WifiTransport(:final client):
        await client.close();
      case UsbTransport(:final session):
        await usb.close(session.handle);
      case _:
        break;
    }
  }

  /// Run a PTP operation against whichever transport is active.
  Future<OpResult> operate(
    int opCode, {
    List<int> params = const [],
    Uint8List? outData,
    bool expectData = false,
  }) async {
    final t = _transport;
    switch (t) {
      case WifiTransport(:final client):
        final dataPhase = expectData
            ? PtpDataPhase.receiveData
            : (outData != null ? PtpDataPhase.sendData : PtpDataPhase.noData);
        final r = await client.operate(
          opCode,
          dataPhase: dataPhase,
          params: params,
          outData: outData,
        );
        return OpResult(code: r.code, params: r.params, data: r.data);
      case UsbTransport(:final session):
        final r = await usb.operate(
          session.handle,
          opCode,
          params: params,
          outData: outData,
          expectData: expectData,
        );
        return OpResult(code: r.code, params: r.params, data: r.data);
      case _:
        throw PtpException('Not connected');
    }
  }

  // ----- High-level Nikon operations --------------------------------------

  Future<void> setControlMode(int mode) =>
      operate(PtpOperation.nikonSetControlMode, params: [mode]);

  Future<void> capture() => operate(PtpOperation.nikonCapture);

  Future<void> startMovie() => operate(PtpOperation.nikonStartMovieRec);
  Future<void> stopMovie() => operate(PtpOperation.nikonEndMovieRec);

  Future<OpResult> startLiveView() =>
      operate(PtpOperation.nikonStartLiveView);
  Future<OpResult> endLiveView() =>
      operate(PtpOperation.nikonEndLiveView);

  /// Fetch one LiveView frame (0x9203). Caller polls this on a timer.
  Future<Uint8List> getLiveViewImg() async {
    final r = await operate(
      PtpOperation.nikonGetLiveViewImg,
      expectData: true,
    );
    if (!r.isOk || r.data == null) {
      throw PtpException('GetLiveViewImg failed: 0x${r.code.toRadixString(16)}');
    }
    return r.data!;
  }

  /// Set a device property value (uint16 or uint32 depending on type).
  Future<void> setDevicePropValue(int propCode, int value) =>
      operate(
        PtpOperation.setDevicePropValue,
        params: [propCode],
        outData: _u16le(value),
      );

  /// Touch-to-focus: normalized (x,y) in [0,1] -> ChangeAfArea(0x9205).
  Future<void> changeAfArea(double nx, double ny) async {
    final px = (nx * 0xFFFF).round() & 0xFFFF;
    final py = (ny * 0xFFFF).round() & 0xFFFF;
    await operate(PtpOperation.nikonChangeAfArea, params: [px, py]);
  }

  /// Trigger autofocus.
  Future<void> afDrive() => operate(PtpOperation.nikonAfDrive);

  /// Manual focus drive: direction 0=near, 1=far; step in small increments.
  Future<void> mfDrive(int direction, int step) =>
      operate(PtpOperation.nikonMfDrive, params: [direction, step]);

  /// Poll async events from the camera (object added, capture complete, etc.).
  Future<OpResult> checkEvent() =>
      operate(PtpOperation.nikonCheckEvent, expectData: true);

  // ----- Auto-reconnect ---------------------------------------------------

  void enableAutoReconnect({
    required Future<void> Function() onReconnecting,
    required void Function(Object) onFailed,
  }) {
    _autoReconnect = true;
    _scheduleReconnect(onReconnecting, onFailed);
  }

  void _scheduleReconnect(
    Future<void> Function() onReconnecting,
    void Function(Object) onFailed,
  ) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () async {
      if (!_autoReconnect || _transport != null) return;
      try {
        await onReconnecting();
        switch (_kind) {
          case CameraTransport.wifi:
            await connectWifi(_lastHost, _lastPort);
          case CameraTransport.usb:
            if (_lastUsbDeviceId != null) {
              await connectUsb(_lastUsbDeviceId!);
            }
          case CameraTransport.none:
            break;
        }
      } catch (e) {
        onFailed(e);
        _scheduleReconnect(onReconnecting, onFailed);
      }
    });
  }
}

Uint8List _u16le(int v) => Uint8List(2)..[0] = v & 0xFF..[1] = (v >> 8) & 0xFF;
