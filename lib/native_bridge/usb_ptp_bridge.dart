// USB PTP bridge — MethodChannel interface to the Android USB Host API.
//
// On Android, USB OTG cannot be accessed from pure Dart; we use a native
// [UsbPtpService] (Kotlin) that wraps android.hardware.usb. The Dart side
// issues the same PTP operations through this bridge, and the native side
// translates them into USB bulk transfers with the PTP framing.
//
// Channel: "nikon_field_monitor/usb_ptp"
//
//   Dart -> Native:
//     hasUsbHost()                       -> bool
//     listUsbDevices()                   -> List<{deviceId, productName, vendorId, productId}>
//     requestPermission(deviceId)        -> bool
//     open(deviceId)                     -> {sessionHandle: int, model: String, firmware: String}
//     close(sessionHandle)               -> null
//     operate(sessionHandle, opCode, [params], data?) -> {code, params, data}
//     startEventStream(sessionHandle)    -> null  (events on EventChannel)
//
//   EventChannel "nikon_field_monitor/usb_ptp/events":
//     {event: "attached", deviceId, productName}
//     {event: "detached", deviceId}
//     {event: "ptpEvent", opCode, params, data}
//
// On iOS this channel always reports unsupported (USB-C requires External
// Accessory framework + MFi — left as a documented TODO).
//
// References:
//   - remoteyourcam-usb: UsbCamera.java, UsbPtpAction.java
//   - gphoto2 camlibs/ptp2/usb.c  (PTP-over-USB bulk transfer framing)
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class UsbPtpDevice {
  const UsbPtpDevice({
    required this.deviceId,
    required this.productName,
    required this.vendorId,
    required this.productId,
  });
  final String deviceId;
  final String productName;
  final int vendorId;
  final int productId;

  @override
  String toString() => 'UsbPtpDevice($productName vid=0x${vendorId.toRadixString(16)} pid=0x${productId.toRadixString(16)})';
}

class UsbPtpOpResult {
  const UsbPtpOpResult({required this.code, required this.params, this.data});
  final int code; // PtpResponse.*
  final List<int> params;
  final Uint8List? data;
  bool get isOk => code == 0x2001;
}

class UsbPtpBridge {
  static const MethodChannel _channel = MethodChannel('nikon_field_monitor/usb_ptp');
  static const EventChannel _eventChannel =
      EventChannel('nikon_field_monitor/usb_ptp/events');

  StreamSubscription<dynamic>? _eventSub;
  final _deviceAttached = StreamController<UsbPtpDevice>.broadcast();
  final _deviceDetached = StreamController<String>.broadcast();
  final _ptpEvent = StreamController<UsbPtpEvent>.broadcast();

  Stream<UsbPtpDevice> get deviceAttached => _deviceAttached.stream;
  Stream<String> get deviceDetached => _deviceDetached.stream;
  Stream<UsbPtpEvent> get ptpEvents => _ptpEvent.stream;

  Future<bool> hasUsbHost() async {
    try {
      return await _channel.invokeMethod<bool>('hasUsbHost') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<List<UsbPtpDevice>> listUsbDevices() async {
    final res = await _channel.invokeMethod<List>('listUsbDevices');
    if (res == null) return const [];
    return res
        .cast<Map>()
        .map((d) => UsbPtpDevice(
              deviceId: d['deviceId'] as String,
              productName: d['productName'] as String? ?? 'Unknown',
              vendorId: (d['vendorId'] as num?)?.toInt() ?? 0,
              productId: (d['productId'] as num?)?.toInt() ?? 0,
            ))
        .toList();
  }

  Future<bool> requestPermission(String deviceId) async =>
      await _channel.invokeMethod<bool>('requestPermission', {'deviceId': deviceId}) ?? false;

  Future<UsbPtpSession> open(String deviceId) async {
    final res = await _channel.invokeMethod<Map>('open', {'deviceId': deviceId});
    if (res == null) {
      throw PlatformException(code: 'USB_OPEN', message: 'open returned null');
    }
    return UsbPtpSession(
      handle: (res['sessionHandle'] as num?)?.toInt() ?? 0,
      model: res['model'] as String? ?? 'Unknown',
      firmware: res['firmware'] as String? ?? '',
    );
  }

  Future<void> close(int sessionHandle) =>
      _channel.invokeMethod<void>('close', {'sessionHandle': sessionHandle});

  Future<UsbPtpOpResult> operate(
    int sessionHandle,
    int opCode, {
    List<int> params = const [],
    Uint8List? outData,
    bool expectData = false,
  }) async {
    final res = await _channel.invokeMethod<Map>('operate', {
      'sessionHandle': sessionHandle,
      'opCode': opCode,
      'params': params,
      'outData': outData,
      'expectData': expectData,
    });
    if (res == null) {
      throw PlatformException(code: 'USB_OP', message: 'operate returned null');
    }
    final data = res['data'];
    return UsbPtpOpResult(
      code: (res['code'] as num?)?.toInt() ?? 0,
      params: (res['params'] as List?)?.cast<int>() ?? const [],
      data: data is Uint8List ? data : (data is List ? Uint8List.fromList(data.cast<int>()) : null),
    );
  }

  void startEventStream() {
    _eventSub?.cancel();
    _eventSub = _eventChannel.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      switch (event['event']) {
        case 'attached':
          _deviceAttached.add(UsbPtpDevice(
            deviceId: event['deviceId'] as String,
            productName: event['productName'] as String? ?? 'Unknown',
            vendorId: (event['vendorId'] as num?)?.toInt() ?? 0,
            productId: (event['productId'] as num?)?.toInt() ?? 0,
          ));
        case 'detached':
          _deviceDetached.add(event['deviceId'] as String);
        case 'ptpEvent':
          _ptpEvent.add(UsbPtpEvent(
            opCode: (event['opCode'] as num?)?.toInt() ?? 0,
            params: (event['params'] as List?)?.cast<int>() ?? const [],
            data: event['data'] is Uint8List
                ? event['data'] as Uint8List
                : null,
          ));
        default:
          break;
      }
    });
  }

  void stopEventStream() {
    _eventSub?.cancel();
    _eventSub = null;
  }

  void dispose() {
    stopEventStream();
    _deviceAttached.close();
    _deviceDetached.close();
    _ptpEvent.close();
  }
}

class UsbPtpSession {
  const UsbPtpSession({
    required this.handle,
    required this.model,
    required this.firmware,
  });
  final int handle;
  final String model;
  final String firmware;
}

class UsbPtpEvent {
  const UsbPtpEvent({required this.opCode, required this.params, this.data});
  final int opCode;
  final List<int> params;
  final Uint8List? data;
}
