// HUD overlay — FPS / latency / resolution + connection badge.
//
// Drawn in the bottom-left corner of the LiveView stack. Toggleable via
// MonitorAssistSettings.hudVisible.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/camera_state.dart';
import '../../models/monitor_assist_settings.dart';
import '../../utils/theme.dart';

class HudOverlay extends ConsumerWidget {
  const HudOverlay({
    super.key,
    required this.telemetry,
    required this.connection,
    required this.settings,
  });

  final AsyncValue<LiveViewTelemetry> telemetry;
  final CameraConnectionState connection;
  final MonitorAssistSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.surfaceVariant, width: 0.5),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: AppColors.onSurface,
          height: 1.25,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _row('FPS', telemetry.maybeWhen(
              data: (t) => t.fps.toStringAsFixed(1),
              orElse: () => '--',
            )),
            _row('LAT', '${telemetry.maybeWhen(
              data: (t) => t.latencyMs,
              orElse: () => 0,
            )} ms'),
            _row('TRAN', connection.transport.name.toUpperCase()),
            if (connection.properties.batteryLevel >= 0)
              _row('BAT', '${connection.properties.batteryLevel}%'),
            _assistBadge(),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) => RichText(
        text: TextSpan(
          children: [
            TextSpan(text: '$k ', style: const TextStyle(color: AppColors.onSurfaceMuted)),
            TextSpan(text: v, style: const TextStyle(color: AppColors.accent)),
          ],
        ),
      );

  Widget _assistBadge() {
    final active = <String>[
      if (settings.peakingEnabled) 'PK',
      if (settings.zebraEnabled) 'ZB',
      if (settings.falseColorEnabled) 'FC',
      if (settings.lutActuallyApplied) 'LUT',
      if (settings.histogramMode != HistogramMode.off) 'HIST',
      if (settings.waveformPlacement != WaveformPlacement.off) 'WFM',
    ];
    if (active.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(active.join(' · '), style: const TextStyle(color: AppColors.cyan, fontSize: 10)),
    );
  }
}
