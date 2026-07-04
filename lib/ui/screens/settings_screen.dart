// Settings screen — language picker + monitoring feature quick toggles.
//
// Opens from the connection screen AppBar (and the LiveView top bar). Changes
// to monitoring toggles here flow through [assistSettingsProvider] so they
// take effect immediately on the GPU pipeline.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_strings.dart';
import '../../models/monitor_assist_settings.dart';
import '../../state/providers.dart';
import '../../utils/theme.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final locale = ref.watch(localeProvider);
    final s = ref.watch(assistSettingsProvider);
    final notifier = ref.read(assistSettingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: Text(t('settings'))),
      body: ListView(
        children: [
          // ----- General -----
          _SectionHeader(t('general')),
          ListTile(
            leading: const Icon(Icons.language, color: AppColors.accent),
            title: Text(t('language')),
            trailing: DropdownButton<AppLocale>(
              value: locale,
              underline: const SizedBox(),
              items: AppLocale.values
                  .map((l) => DropdownMenuItem(
                        value: l,
                        child: Text(localeLabel(l)),
                      ))
                  .toList(),
              onChanged: (l) {
                if (l != null) ref.read(localeProvider.notifier).set(l);
              },
            ),
          ),
          const Divider(),

          // ----- Monitoring features -----
          _SectionHeader(t('monitoringFeatures')),
          SwitchListTile(
            secondary: const Icon(Icons.palette_outlined, color: AppColors.accent),
            title: Text(t('enableFalseColor')),
            subtitle: Text(t('falseColorHint'),
                style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted)),
            value: s.falseColorEnabled,
            onChanged: (v) => notifier.update(s.copyWith(
              falseColorEnabled: v,
              lutEnabled: v ? false : s.lutEnabled,
            )),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.show_chart, color: AppColors.accent),
            title: Text(t('enableWaveform')),
            subtitle: Text(t('waveformHint'),
                style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted)),
            value: s.waveformPlacement != WaveformPlacement.off,
            onChanged: (v) => notifier.update(s.copyWith(
              waveformPlacement:
                  v ? WaveformPlacement.bottom : WaveformPlacement.off,
            )),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.bar_chart, color: AppColors.accent),
            title: Text(t('enableHistogram')),
            subtitle: Text(t('histogramHint'),
                style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted)),
            value: s.histogramMode != HistogramMode.off,
            onChanged: (v) => notifier.update(s.copyWith(
              histogramMode: v ? HistogramMode.luma : HistogramMode.off,
            )),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.center_focus_strong, color: AppColors.accent),
            title: Text(t('enablePeaking')),
            subtitle: Text(t('peakingHint'),
                style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted)),
            value: s.peakingEnabled,
            onChanged: (v) =>
                notifier.update(s.copyWith(peakingEnabled: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.waves, color: AppColors.accent),
            title: Text(t('enableZebra')),
            subtitle: Text(t('zebraHint'),
                style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted)),
            value: s.zebraEnabled,
            onChanged: (v) =>
                notifier.update(s.copyWith(zebraEnabled: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.tune, color: AppColors.accent),
            title: Text(t('enableLutSetting')),
            subtitle: Text(t('lutHint'),
                style: const TextStyle(fontSize: 12, color: AppColors.onSurfaceMuted)),
            value: s.lutEnabled,
            onChanged: s.falseColorEnabled
                ? null
                : (v) => notifier.update(s.copyWith(lutEnabled: v)),
          ),
          const Divider(),
          SwitchListTile(
            secondary: const Icon(Icons.info_outline, color: AppColors.accent),
            title: Text(t('showHud')),
            value: s.hudVisible,
            onChanged: (v) => notifier.update(s.copyWith(hudVisible: v)),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.accent,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
