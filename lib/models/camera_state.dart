// Camera connection state + camera-reported device properties.
//
// Drives the connection-management page and the parameter drawer. Updated by
// [ConnectionService] from PTP GetDeviceInfo + GetDevicePropValue responses
// and by periodic CheckEvent (0x90C7) polling.
library;

import 'package:flutter/foundation.dart';

/// Transport used to reach the camera.
enum CameraTransport { wifi, usb, none }

/// Connection lifecycle phase shown in the UI.
enum ConnectionPhase {
  disconnected,
  discovering,
  connecting,
  authenticating,
  connected,
  liveViewStarting,
  liveViewActive,
  error,
}

/// Snapshot of camera-exposed device properties (the parameter drawer).
@immutable
class CameraProperties {
  const CameraProperties({
    this.model = 'Unknown',
    this.manufacturer = 'Nikon',
    this.firmwareVersion = '',
    this.serialNumber = '',
    this.batteryLevel = -1, // -1 = unknown, 0..100
    this.iso = 0,
    this.shutterSpeed = '',
    this.aperture = '',
    this.exposureCompensation = '',
    this.whiteBalance = '',
    this.exposureMode = '',
    this.shootingMode = '',
  });

  final String model;
  final String manufacturer;
  final String firmwareVersion;
  final String serialNumber;
  final int batteryLevel; // 0..100 or -1
  final int iso; // e.g. 100, 200, 400, 800
  final String shutterSpeed; // "1/250", "1/60", "1/30"
  final String aperture; // "f/2.8"
  final String exposureCompensation; // "+0.3", "-1.0"
  final String whiteBalance; // "Daylight", "Auto"
  final String exposureMode; // "P", "S", "A", "M"
  final String shootingMode; // "Single", "Continuous"

  CameraProperties copyWith({
    String? model,
    String? manufacturer,
    String? firmwareVersion,
    String? serialNumber,
    int? batteryLevel,
    int? iso,
    String? shutterSpeed,
    String? aperture,
    String? exposureCompensation,
    String? whiteBalance,
    String? exposureMode,
    String? shootingMode,
  }) {
    return CameraProperties(
      model: model ?? this.model,
      manufacturer: manufacturer ?? this.manufacturer,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      serialNumber: serialNumber ?? this.serialNumber,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      iso: iso ?? this.iso,
      shutterSpeed: shutterSpeed ?? this.shutterSpeed,
      aperture: aperture ?? this.aperture,
      exposureCompensation: exposureCompensation ?? this.exposureCompensation,
      whiteBalance: whiteBalance ?? this.whiteBalance,
      exposureMode: exposureMode ?? this.exposureMode,
      shootingMode: shootingMode ?? this.shootingMode,
    );
  }

  static const CameraProperties empty = CameraProperties();
}

/// Saved connection for the history list.
@immutable
class SavedConnection {
  const SavedConnection({
    required this.id,
    required this.label,
    required this.transport,
    required this.host, // IP for wifi, USB device name for usb
    this.port = 15740,
    this.lastUsed,
  });

  final String id;
  final String label;
  final CameraTransport transport;
  final String host;
  final int port;
  final DateTime? lastUsed;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'transport': transport.name,
    'host': host,
    'port': port,
    'lastUsed': lastUsed?.toIso8601String(),
  };

  factory SavedConnection.fromJson(Map<String, Object?> json) {
    CameraTransport parseTransport(String? s) => switch (s) {
      'wifi' => CameraTransport.wifi,
      'usb' => CameraTransport.usb,
      _ => CameraTransport.wifi,
    };
    return SavedConnection(
      id: json['id'] as String,
      label: json['label'] as String,
      transport: parseTransport(json['transport'] as String?),
      host: json['host'] as String,
      port: (json['port'] as num?)?.toInt() ?? 15740,
      lastUsed: json['lastUsed'] == null
          ? null
          : DateTime.parse(json['lastUsed'] as String),
    );
  }
}

/// The full camera connection state used by Riverpod.
@immutable
class CameraConnectionState {
  const CameraConnectionState({
    this.phase = ConnectionPhase.disconnected,
    this.transport = CameraTransport.none,
    this.properties = CameraProperties.empty,
    this.host = '',
    this.port = 15740,
    this.error,
    this.lastConnected,
  });

  final ConnectionPhase phase;
  final CameraTransport transport;
  final CameraProperties properties;
  final String host;
  final int port;
  final String? error;
  final DateTime? lastConnected;

  bool get isConnected => phase == ConnectionPhase.connected ||
      phase == ConnectionPhase.liveViewStarting ||
      phase == ConnectionPhase.liveViewActive;
  bool get isLiveViewActive => phase == ConnectionPhase.liveViewActive;

  CameraConnectionState copyWith({
    ConnectionPhase? phase,
    CameraTransport? transport,
    CameraProperties? properties,
    String? host,
    int? port,
    Object? error = _sentinel,
    DateTime? lastConnected,
  }) {
    return CameraConnectionState(
      phase: phase ?? this.phase,
      transport: transport ?? this.transport,
      properties: properties ?? this.properties,
      host: host ?? this.host,
      port: port ?? this.port,
      error: identical(error, _sentinel) ? this.error : error as String?,
      lastConnected: lastConnected ?? this.lastConnected,
    );
  }

  static const CameraConnectionState initial = CameraConnectionState();
}

const Object _sentinel = Object();

/// Live telemetry shown in the HUD.
@immutable
class LiveViewTelemetry {
  const LiveViewTelemetry({
    this.fps = 0,
    this.latencyMs = 0,
    this.frameCount = 0,
    this.lastFrameAt,
  });

  final double fps;
  final int latencyMs;
  final int frameCount;
  final DateTime? lastFrameAt;

  LiveViewTelemetry copyWith({
    double? fps,
    int? latencyMs,
    int? frameCount,
    DateTime? lastFrameAt,
  }) {
    return LiveViewTelemetry(
      fps: fps ?? this.fps,
      latencyMs: latencyMs ?? this.latencyMs,
      frameCount: frameCount ?? this.frameCount,
      lastFrameAt: lastFrameAt ?? this.lastFrameAt,
    );
  }
}
