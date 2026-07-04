// Preferences service — persists MonitorAssistSettings + saved connections
// via shared_preferences (Android: SharedPreferences, iOS: NSUserDefaults).
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_strings.dart';
import '../models/camera_state.dart';
import '../models/monitor_assist_settings.dart';

class PreferencesService {
  static const _kAssist = 'monitor_assist_settings';
  static const _kConnections = 'saved_connections';
  static const _kLocale = 'app_locale';

  Future<MonitorAssistSettings> loadAssistSettings() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kAssist);
    if (raw == null) return MonitorAssistSettings();
    final m = jsonDecode(raw) as Map<String, Object?>;
    return MonitorAssistSettings.fromPrefsMap(m);
  }

  Future<void> saveAssistSettings(MonitorAssistSettings s) async {
    final sp = await SharedPreferences.getInstance();
    final m = s.toPrefsMap();
    await sp.setString(_kAssist, jsonEncode(m));
  }

  Future<List<SavedConnection>> loadConnections() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kConnections);
    if (raw == null) return const [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .cast<Map<String, Object?>>()
        .map(SavedConnection.fromJson)
        .toList();
  }

  Future<void> saveConnections(List<SavedConnection> connections) async {
    final sp = await SharedPreferences.getInstance();
    final list = connections.map((c) => c.toJson()).toList();
    await sp.setString(_kConnections, jsonEncode(list));
  }

  Future<AppLocale> loadLocale() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kLocale);
    return switch (raw) {
      'zhCN' => AppLocale.zhCN,
      'zhTW' => AppLocale.zhTW,
      _ => AppLocale.en,
    };
  }

  Future<void> saveLocale(AppLocale l) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kLocale, l.name);
  }
}
