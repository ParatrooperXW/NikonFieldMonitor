// Monitor assist settings — the full GPU post-processing configuration.
//
// All toggles are independently switchable except:
//   * falseColor & LUT are MUTUALLY EXCLUSIVE (falseColor wins when both on).
//   * peaking & zebra CAN combine.
//
// Persisted via SharedPreferences / UserDefaults. See [PreferencesService].
library;

import 'package:flutter/material.dart';

/// Focus peaking sensitivity presets.
enum PeakingSensitivity { low, medium, high }

/// Focus peaking overlay color.
enum PeakingColor { red, green, blue, yellow, white }

/// Histogram mode.
enum HistogramMode { off, luma, rgbParade }

/// Waveform monitor placement + opacity.
enum WaveformPlacement { off, bottom, side }

/// Safe-frame overlay options.
enum SafeFrame { none, ratio16x9, ratio2_39x1, ratio4x3, centerCross }

/// IRE zebra preset.
class ZebraRange {
  const ZebraRange(this.lower, this.upper);
  final int lower; // 0..100 IRE
  final int upper; // 0..100 IRE
  static const ZebraRange skinTone = ZebraRange(70, 100);
  static const ZebraRange overexpose = ZebraRange(90, 100);
}

class MonitorAssistSettings {
  MonitorAssistSettings({
    this.peakingEnabled = false,
    this.peakingColor = PeakingColor.red,
    this.peakingSensitivity = PeakingSensitivity.medium,
    this.zebraEnabled = false,
    this.zebraLower = 70,
    this.zebraUpper = 100,
    this.falseColorEnabled = false,
    this.lutEnabled = false,
    this.activeLutId,
    this.histogramMode = HistogramMode.off,
    this.waveformPlacement = WaveformPlacement.off,
    this.waveformOpacity = 0.6,
    this.safeFrame = SafeFrame.none,
    this.hudVisible = true,
  });

  final bool peakingEnabled;
  final PeakingColor peakingColor;
  final PeakingSensitivity peakingSensitivity;

  final bool zebraEnabled;
  final int zebraLower; // 0..100 IRE
  final int zebraUpper; // 0..100 IRE

  final bool falseColorEnabled;

  final bool lutEnabled;
  final String? activeLutId;

  final HistogramMode histogramMode;
  final WaveformPlacement waveformPlacement;
  final double waveformOpacity; // 0..1

  final SafeFrame safeFrame;

  final bool hudVisible;

  /// Effective LUT application: LUT runs only when enabled AND falseColor off.
  bool get lutActuallyApplied => lutEnabled && !falseColorEnabled;

  MonitorAssistSettings copyWith({
    bool? peakingEnabled,
    PeakingColor? peakingColor,
    PeakingSensitivity? peakingSensitivity,
    bool? zebraEnabled,
    int? zebraLower,
    int? zebraUpper,
    bool? falseColorEnabled,
    bool? lutEnabled,
    Object? activeLutId = _sentinel,
    HistogramMode? histogramMode,
    WaveformPlacement? waveformPlacement,
    double? waveformOpacity,
    SafeFrame? safeFrame,
    bool? hudVisible,
  }) {
    return MonitorAssistSettings(
      peakingEnabled: peakingEnabled ?? this.peakingEnabled,
      peakingColor: peakingColor ?? this.peakingColor,
      peakingSensitivity: peakingSensitivity ?? this.peakingSensitivity,
      zebraEnabled: zebraEnabled ?? this.zebraEnabled,
      zebraLower: zebraLower ?? this.zebraLower,
      zebraUpper: zebraUpper ?? this.zebraUpper,
      falseColorEnabled: falseColorEnabled ?? this.falseColorEnabled,
      lutEnabled: lutEnabled ?? this.lutEnabled,
      activeLutId: identical(activeLutId, _sentinel) ? this.activeLutId : activeLutId as String?,
      histogramMode: histogramMode ?? this.histogramMode,
      waveformPlacement: waveformPlacement ?? this.waveformPlacement,
      waveformOpacity: waveformOpacity ?? this.waveformOpacity,
      safeFrame: safeFrame ?? this.safeFrame,
      hudVisible: hudVisible ?? this.hudVisible,
    );
  }

  /// Pack into a Map for the native render bridge (MethodChannel).
  Map<String, Object?> toBridgeMap() {
    return <String, Object?>{
      'peakingEnabled': peakingEnabled,
      'peakingColor': peakingColor.name,
      'peakingSensitivity': peakingSensitivity.index, // 0/1/2 -> threshold scale
      'zebraEnabled': zebraEnabled,
      'zebraLowerIre': zebraLower,
      'zebraUpperIre': zebraUpper,
      'falseColorEnabled': falseColorEnabled,
      'lutEnabled': lutActuallyApplied,
      'activeLutId': activeLutId,
      'histogramMode': histogramMode.index,
      'waveformPlacement': waveformPlacement.index,
      'waveformOpacity': waveformOpacity,
      'safeFrame': safeFrame.index,
      'hudVisible': hudVisible,
    };
  }

  // ----- Persistence (SharedPreferences expects primitives) ---------------

  Map<String, Object?> toPrefsMap() => toBridgeMap();

  factory MonitorAssistSettings.fromPrefsMap(Map<String, Object?> m) {
    PeakingColor parsePeakingColor(String? s) => switch (s) {
      'red' => PeakingColor.red,
      'green' => PeakingColor.green,
      'blue' => PeakingColor.blue,
      'yellow' => PeakingColor.yellow,
      'white' => PeakingColor.white,
      _ => PeakingColor.red,
    };
    return MonitorAssistSettings(
      peakingEnabled: m['peakingEnabled'] as bool? ?? false,
      peakingColor: parsePeakingColor(m['peakingColor'] as String?),
      peakingSensitivity: PeakingSensitivity.values[(m['peakingSensitivity'] as int?) ?? 1],
      zebraEnabled: m['zebraEnabled'] as bool? ?? false,
      zebraLower: (m['zebraLowerIre'] as num?)?.toInt() ?? 70,
      zebraUpper: (m['zebraUpperIre'] as num?)?.toInt() ?? 100,
      falseColorEnabled: m['falseColorEnabled'] as bool? ?? false,
      lutEnabled: m['lutEnabled'] as bool? ?? false,
      activeLutId: m['activeLutId'] as String?,
      histogramMode: HistogramMode.values[(m['histogramMode'] as int?) ?? 0],
      waveformPlacement: WaveformPlacement.values[(m['waveformPlacement'] as int?) ?? 0],
      waveformOpacity: (m['waveformOpacity'] as num?)?.toDouble() ?? 0.6,
      safeFrame: SafeFrame.values[(m['safeFrame'] as int?) ?? 0],
      hudVisible: m['hudVisible'] as bool? ?? true,
    );
  }
}

const Object _sentinel = Object();

/// Convenience: Material color swatch for each peaking color.
Color peakingColorValue(PeakingColor c) => switch (c) {
  PeakingColor.red => const Color(0xFFFF0000),
  PeakingColor.green => const Color(0xFF00FF00),
  PeakingColor.blue => const Color(0xFF00B0FF),
  PeakingColor.yellow => const Color(0xFFFFFF00),
  PeakingColor.white => const Color(0xFFFFFFFF),
};
