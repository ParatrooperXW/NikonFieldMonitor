// Assist menu sheet — the full monitoring-assist configuration popover.
//
// Layout matches the spec:
//   ┌ 监看辅助 ───────────────────────────┐
//   │ ☑ 峰值对焦   [颜色 ▼] [灵敏度 ▼]
//   │ ☑ 斑马纹     [IRE下限 ▽] – [IRE上限 ▽]
//   │ ☑ 伪色       (自动关闭 LUT)
//   │ ☑ 启用 LUT   [选择 LUT ▼]
//   │ ☑ 直方图     (亮度 / RGB Parade)
//   │ ☑ 波形图     (底/侧，可调透明度)
//   │ ☑ 安全框     (16:9 / 2.39:1 / 4:3 / 中心十字)
//   └──────────────────────────────────────┘
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/monitor_assist_settings.dart';
import '../../state/providers.dart';
import '../../utils/theme.dart';

class AssistMenuSheet extends ConsumerWidget {
  const AssistMenuSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final s = ref.watch(assistSettingsProvider);
    final notifier = ref.read(assistSettingsProvider.notifier);
    final luts = ref.watch(lutsProvider);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.movie_creation_outlined, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Text(t('monitorAssist'),
                      style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
              const Divider(height: 24),

              // Peaking
              _SwitchRow(
                title: t('focusPeaking'),
                value: s.peakingEnabled,
                onChanged: (v) => notifier.update(s.copyWith(peakingEnabled: v)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Dropdown<PeakingColor>(
                      value: s.peakingColor,
                      items: PeakingColor.values,
                      label: (c) => c.name,
                      onChanged: (c) => notifier.update(s.copyWith(peakingColor: c)),
                    ),
                    const SizedBox(width: 8),
                    _Dropdown<PeakingSensitivity>(
                      value: s.peakingSensitivity,
                      items: PeakingSensitivity.values,
                      label: (s) => s.name,
                      onChanged: (s2) =>
                          notifier.update(s.copyWith(peakingSensitivity: s2)),
                    ),
                  ],
                ),
              ),

              // Zebra
              _SwitchRow(
                title: t('zebrasIre'),
                value: s.zebraEnabled,
                onChanged: (v) => notifier.update(s.copyWith(zebraEnabled: v)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _IreSpinner(
                      label: t('lower'),
                      value: s.zebraLower,
                      onChanged: (v) => notifier.update(s.copyWith(zebraLower: v)),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Text('–'),
                    ),
                    _IreSpinner(
                      label: t('upper'),
                      value: s.zebraUpper,
                      onChanged: (v) => notifier.update(s.copyWith(zebraUpper: v)),
                    ),
                  ],
                ),
              ),

              // False color (mutex with LUT)
              _SwitchRow(
                title: t('falseColor'),
                subtitle: s.falseColorEnabled ? t('falseColorLutDisabled') : null,
                value: s.falseColorEnabled,
                onChanged: (v) => notifier.update(s.copyWith(
                  falseColorEnabled: v,
                  lutEnabled: v ? false : s.lutEnabled,
                )),
              ),

              // LUT
              _SwitchRow(
                title: t('enableLut'),
                subtitle: s.falseColorEnabled ? t('lutDisabledByFalseColor') : null,
                value: s.lutEnabled,
                onChanged: s.falseColorEnabled
                    ? null
                    : (v) => notifier.update(s.copyWith(lutEnabled: v)),
                trailing: luts.when(
                  data: (map) => _Dropdown<String>(
                    value: s.activeLutId ?? (map.keys.isNotEmpty ? map.keys.first : null),
                    items: map.keys.toList(),
                    label: (id) => map[id]?.name ?? '—',
                    onChanged: (id) => notifier.update(s.copyWith(activeLutId: id)),
                  ),
                  loading: () => const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  error: (e, _) => Text(t('lutLoadFailed', params: {'error': '$e'}),
                      style: const TextStyle(color: AppColors.red, fontSize: 12)),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _importLut(context, ref),
                  icon: const Icon(Icons.file_upload_outlined, size: 18),
                  label: Text(t('importCubeLut')),
                ),
              ),

              const Divider(height: 16),

              // Histogram
              _SwitchRow(
                title: t('histogram'),
                value: s.histogramMode != HistogramMode.off,
                onChanged: (v) => notifier.update(s.copyWith(
                  histogramMode: v ? HistogramMode.luma : HistogramMode.off,
                )),
                trailing: _Dropdown<HistogramMode>(
                  value: s.histogramMode == HistogramMode.off
                      ? HistogramMode.luma
                      : s.histogramMode,
                  items: const [HistogramMode.luma, HistogramMode.rgbParade],
                  label: (m) => m == HistogramMode.luma ? t('luma') : t('rgbParade'),
                  onChanged: (m) => notifier.update(s.copyWith(histogramMode: m)),
                ),
              ),

              // Waveform
              _SwitchRow(
                title: t('waveformMonitor'),
                value: s.waveformPlacement != WaveformPlacement.off,
                onChanged: (v) => notifier.update(s.copyWith(
                  waveformPlacement: v
                      ? WaveformPlacement.bottom
                      : WaveformPlacement.off,
                )),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Dropdown<WaveformPlacement>(
                      value: s.waveformPlacement == WaveformPlacement.off
                          ? WaveformPlacement.bottom
                          : s.waveformPlacement,
                      items: const [
                        WaveformPlacement.bottom,
                        WaveformPlacement.side,
                      ],
                      label: (p) => p == WaveformPlacement.bottom ? t('bottom') : t('side'),
                      onChanged: (p) =>
                          notifier.update(s.copyWith(waveformPlacement: p)),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 90,
                      child: Slider(
                        value: s.waveformOpacity,
                        min: 0.2,
                        max: 1.0,
                        onChanged: (v) =>
                            notifier.update(s.copyWith(waveformOpacity: v)),
                      ),
                    ),
                  ],
                ),
              ),

              // Safe frame
              _SwitchRow(
                title: t('safeFrame'),
                value: s.safeFrame != SafeFrame.none,
                onChanged: (v) => notifier.update(s.copyWith(
                  safeFrame: v ? SafeFrame.ratio16x9 : SafeFrame.none,
                )),
                trailing: _Dropdown<SafeFrame>(
                  value: s.safeFrame == SafeFrame.none
                      ? SafeFrame.ratio16x9
                      : s.safeFrame,
                  items: const [
                    SafeFrame.ratio16x9,
                    SafeFrame.ratio2_39x1,
                    SafeFrame.ratio4x3,
                    SafeFrame.centerCross,
                  ],
                  label: (sf) => switch (sf) {
                    SafeFrame.ratio16x9 => '16:9',
                    SafeFrame.ratio2_39x1 => '2.39:1',
                    SafeFrame.ratio4x3 => '4:3',
                    SafeFrame.centerCross => t('centerCross'),
                    SafeFrame.none => t('off'),
                  },
                  onChanged: (sf) => notifier.update(s.copyWith(safeFrame: sf)),
                ),
              ),

              const Divider(height: 16),

              SwitchListTile(
                title: Text(t('showHud')),
                value: s.hudVisible,
                onChanged: (v) => notifier.update(s.copyWith(hudVisible: v)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _importLut(BuildContext context, WidgetRef ref) async {
    final t = ref.read(stringsProvider);
    final svc = ref.read(lutServiceProvider);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['cube'],
      );
      if (result == null || result.files.single.path == null) return;
      final file = File(result.files.single.path!);
      final lut = await svc.importFromFile(file);
      // refresh the FutureProvider so the dropdown updates
      ref.invalidate(lutsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('importedLut', params: {'name': lut.name}))),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('importFailed', params: {'error': '$e'}))),
        );
      }
    }
  }
}

// ----- Reusable controls --------------------------------------------------

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.trailing,
  });
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!, style: const TextStyle(fontSize: 11, color: AppColors.onSurfaceMuted)),
      value: value,
      onChanged: onChanged,
      secondary: Icon(
        value ? Icons.check_circle : Icons.radio_button_unchecked,
        color: value ? AppColors.accent : AppColors.onSurfaceMuted,
        size: 18,
      ),
      controlAffinity: ListTileControlAffinity.leading,
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.items,
    required this.label,
    required this.onChanged,
  });
  final T? value;
  final List<T> items;
  final String Function(T) label;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 130,
      child: DropdownButtonFormField<T>(
        value: value,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(),
        ),
        items: items
            .map((t) => DropdownMenuItem<T>(value: t, child: Text(label(t), style: const TextStyle(fontSize: 12))))
            .toList(),
        onChanged: onChanged == null
            ? null
            : (v) {
                if (v != null) onChanged!(v);
              },
      ),
    );
  }
}

class _IreSpinner extends StatelessWidget {
  const _IreSpinner({required this.label, required this.value, required this.onChanged});
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_drop_up, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => onChanged((value + 1).clamp(0, 100)),
          ),
          Text('$value', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          Text(label, style: const TextStyle(fontSize: 9, color: AppColors.onSurfaceMuted)),
          IconButton(
            icon: const Icon(Icons.arrow_drop_down, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => onChanged((value - 1).clamp(0, 100)),
          ),
        ],
      ),
    );
  }
}
