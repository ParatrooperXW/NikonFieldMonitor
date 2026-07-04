// Riverpod providers — the single source of truth for all app state.
//
// We use plain Provider/NotifierProvider (no codegen) so the project compiles
// without running build_runner first. State objects are immutable.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_strings.dart';
import '../models/camera_state.dart';
import '../models/lut_model.dart';
import '../models/monitor_assist_settings.dart';
import '../native_bridge/native_render_bridge.dart';
import '../native_bridge/usb_ptp_bridge.dart';
import '../services/connection_service.dart';
import '../services/liveview_service.dart';
import '../services/lut_service.dart';
import '../services/preferences_service.dart';

// ----- Bridges / singletons ----------------------------------------------

final renderBridgeProvider = Provider<RenderBridge>((ref) {
  final b = RenderBridge();
  ref.onDispose(b.dispose);
  return b;
});

final usbPtpBridgeProvider = Provider<UsbPtpBridge>((ref) {
  final b = UsbPtpBridge();
  ref.onDispose(b.dispose);
  return b;
});

final preferencesServiceProvider = Provider<PreferencesService>((ref) {
  return PreferencesService();
});

// ----- Services -----------------------------------------------------------

final connectionServiceProvider = Provider<ConnectionService>((ref) {
  final usb = ref.watch(usbPtpBridgeProvider);
  final svc = ConnectionService(usb: usb);
  ref.onDispose(svc.disconnect);
  return svc;
});

final liveViewServiceProvider = Provider<LiveViewService>((ref) {
  final conn = ref.watch(connectionServiceProvider);
  final bridge = ref.watch(renderBridgeProvider);
  final svc = LiveViewService(connection: conn, bridge: bridge);
  ref.onDispose(svc.dispose);
  return svc;
});

final lutServiceProvider = Provider<LutService>((ref) {
  final bridge = ref.watch(renderBridgeProvider);
  return LutService(bridge);
});

// ----- Camera connection state -------------------------------------------

class CameraConnectionNotifier extends StateNotifier<CameraConnectionState> {
  CameraConnectionNotifier(this._conn) : super(CameraConnectionState.initial);
  final ConnectionService _conn;

  Future<void> connectWifi(String host, [int port = 15740]) async {
    state = state.copyWith(
      phase: ConnectionPhase.connecting,
      transport: CameraTransport.wifi,
      host: host,
      port: port,
      error: null,
    );
    try {
      await _conn.connectWifi(host, port);
      state = state.copyWith(
        phase: ConnectionPhase.connected,
        lastConnected: DateTime.now(),
      );
    } catch (e) {
      state = state.copyWith(phase: ConnectionPhase.error, error: e.toString());
    }
  }

  Future<void> connectUsb(String deviceId) async {
    state = state.copyWith(
      phase: ConnectionPhase.connecting,
      transport: CameraTransport.usb,
      host: deviceId,
      error: null,
    );
    try {
      final session = await _conn.connectUsb(deviceId);
      state = state.copyWith(
        phase: ConnectionPhase.connected,
        properties: CameraProperties(model: session.model, firmwareVersion: session.firmware),
        lastConnected: DateTime.now(),
      );
    } catch (e) {
      state = state.copyWith(phase: ConnectionPhase.error, error: e.toString());
    }
  }

  Future<void> disconnect() async {
    await _conn.disconnect();
    state = CameraConnectionState.initial;
  }

  void setPhase(ConnectionPhase phase) {
    state = state.copyWith(phase: phase);
  }

  void updateProperties(CameraProperties props) {
    state = state.copyWith(properties: props);
  }

  void setError(String? error) {
    state = state.copyWith(error: error);
  }
}

final cameraConnectionProvider =
    StateNotifierProvider<CameraConnectionNotifier, CameraConnectionState>(
  (ref) {
    final conn = ref.watch(connectionServiceProvider);
    return CameraConnectionNotifier(conn);
  },
);

// ----- LiveView telemetry -------------------------------------------------

final liveViewTelemetryProvider = StreamProvider<LiveViewTelemetry>((ref) {
  final svc = ref.watch(liveViewServiceProvider);
  return svc.telemetry;
});

// ----- Assist settings ----------------------------------------------------

class AssistSettingsNotifier extends StateNotifier<MonitorAssistSettings> {
  AssistSettingsNotifier(this._prefs) : super(MonitorAssistSettings()) {
    _load();
  }
  final PreferencesService _prefs;

  Future<void> _load() async {
    state = await _prefs.loadAssistSettings();
  }

  Future<void> update(MonitorAssistSettings s) async {
    state = s;
    await _prefs.saveAssistSettings(s);
  }
}

final assistSettingsProvider =
    StateNotifierProvider<AssistSettingsNotifier, MonitorAssistSettings>(
  (ref) {
    final prefs = ref.watch(preferencesServiceProvider);
    return AssistSettingsNotifier(prefs);
  },
);

// ----- LUT registry -------------------------------------------------------

final lutsProvider = FutureProvider<Map<String, LutModel>>((ref) async {
  final svc = ref.watch(lutServiceProvider);
  await svc.init();
  return svc.luts;
});

// ----- Saved connections --------------------------------------------------

final savedConnectionsProvider =
    StateNotifierProvider<SavedConnectionsNotifier, List<SavedConnection>>(
  (ref) {
    final prefs = ref.watch(preferencesServiceProvider);
    return SavedConnectionsNotifier(prefs);
  },
);

class SavedConnectionsNotifier extends StateNotifier<List<SavedConnection>> {
  SavedConnectionsNotifier(this._prefs) : super(const []) {
    _load();
  }
  final PreferencesService _prefs;

  Future<void> _load() async {
    state = await _prefs.loadConnections();
  }

  Future<void> add(SavedConnection c) async {
    state = [...state.where((e) => e.id != c.id), c];
    await _prefs.saveConnections(state);
  }

  Future<void> remove(String id) async {
    state = state.where((e) => e.id != id).toList();
    await _prefs.saveConnections(state);
  }
}

// ----- Locale -------------------------------------------------------------

class LocaleNotifier extends StateNotifier<AppLocale> {
  LocaleNotifier(this._prefs) : super(AppLocale.en) {
    _load();
  }
  final PreferencesService _prefs;

  Future<void> _load() async {
    state = await _prefs.loadLocale();
  }

  Future<void> set(AppLocale l) async {
    state = l;
    await _prefs.saveLocale(l);
  }
}

final localeProvider =
    StateNotifierProvider<LocaleNotifier, AppLocale>((ref) {
  final prefs = ref.watch(preferencesServiceProvider);
  return LocaleNotifier(prefs);
});

/// Convenience: returns an [AppStrings] bound to the current locale.
final stringsProvider = Provider<AppStrings>((ref) {
  final l = ref.watch(localeProvider);
  return AppStrings.of(l);
});
