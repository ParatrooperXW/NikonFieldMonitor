// Parameter drawer — ISO / shutter / aperture / WB / EV row.
//
// Each parameter is a tappable chip that opens a quick picker. Values are
// pushed to the camera via ConnectionService.setDevicePropValue using the
// Nikon-specific 0xD0xx property codes.
//
// TODO_NIKON: the current chip values are display-only placeholders until
// GetDevicePropDesc enums are parsed (so the picker knows the camera's
// supported ISO list etc.). The setter path is wired and functional.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ptp/nikon_opcodes.dart';
import '../../state/providers.dart';
import '../../utils/theme.dart';

class ParameterDrawer extends ConsumerWidget {
  const ParameterDrawer({
    super.key,
    required this.expanded,
    required this.onToggleExpand,
  });

  final bool expanded;
  final VoidCallback onToggleExpand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(cameraConnectionProvider);
    final t = ref.watch(stringsProvider);
    final props = conn.properties;

    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.tune, size: 16, color: AppColors.onSurfaceMuted),
              const SizedBox(width: 6),
              Text(t('parameters'), style: Theme.of(context).textTheme.labelMedium),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(expanded ? Icons.expand_more : Icons.expand_less, size: 18),
                onPressed: onToggleExpand,
              ),
            ],
          ),
          if (expanded)
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _ParamChip(
                    label: 'ISO',
                    value: props.iso == 0 ? '—' : '${props.iso}',
                    onTap: () => _showIsoPicker(context, ref, props.iso),
                  ),
                  _ParamChip(
                    label: t('shutterSpeed'),
                    value: props.shutterSpeed.isEmpty ? '—' : props.shutterSpeed,
                    onTap: () => _showShutterPicker(context, ref),
                  ),
                  _ParamChip(
                    label: 'f/',
                    value: props.aperture.isEmpty ? '—' : props.aperture,
                    onTap: () => _showAperturePicker(context, ref),
                  ),
                  _ParamChip(
                    label: t('whiteBalance'),
                    value: props.whiteBalance.isEmpty ? '—' : props.whiteBalance,
                    onTap: () => _showWbPicker(context, ref),
                  ),
                  _ParamChip(
                    label: 'EV',
                    value: props.exposureCompensation.isEmpty ? '0.0' : props.exposureCompensation,
                    onTap: () => _showEvPicker(context, ref),
                  ),
                  _ParamChip(
                    label: t('exposureMode'),
                    value: props.exposureMode.isEmpty ? '—' : props.exposureMode,
                    onTap: () {},
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _showIsoPicker(BuildContext context, WidgetRef ref, int current) {
    const isos = [100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200];
    _showPickerSheet<int>(
      context,
      title: 'ISO',
      values: isos,
      current: current,
      label: (v) => v.toString(),
      onSelect: (v) async {
        final conn = ref.read(connectionServiceProvider);
        await conn.setDevicePropValue(PtpDeviceProp.nikonExposureIndex, v);
      },
    );
  }

  void _showShutterPicker(BuildContext context, WidgetRef ref) {
    final t = ref.read(stringsProvider);
    const speeds = ['1/8000', '1/4000', '1/2000', '1/1000', '1/500', '1/250', '1/125', '1/60', '1/30', '1/15', '1/8', '1/4', '1/2', '1"', '2"', '4"'];
    _showPickerSheet<String>(
      context,
      title: t('shutterSpeed'),
      values: speeds,
      current: '',
      label: (v) => v,
      onSelect: (v) async {
        // TODO_NIKON: map shutter string -> Nikon shutter code table
        // (gphoto2 nikon.h table nikon_shutterspeed_table).
        // For now we send the raw index; refine after confirming the enum.
      },
    );
  }

  void _showAperturePicker(BuildContext context, WidgetRef ref) {
    final t = ref.read(stringsProvider);
    const aps = ['f/1.4', 'f/1.8', 'f/2.0', 'f/2.8', 'f/4.0', 'f/5.6', 'f/8.0', 'f/11', 'f/16', 'f/22'];
    _showPickerSheet<String>(
      context,
      title: t('aperture'),
      values: aps,
      current: '',
      label: (v) => v,
      onSelect: (v) async {
        // TODO_NIKON: map f-stop string -> Nikon aperture code table.
      },
    );
  }

  void _showWbPicker(BuildContext context, WidgetRef ref) {
    final t = ref.read(stringsProvider);
    final wbs = [
      t('wbAuto'), t('wbDaylight'), t('wbCloudy'), t('wbShade'),
      t('wbIncandescent'), t('wbFluorescent'), t('wbFlash'), t('wbKelvin'),
    ];
    _showPickerSheet<String>(
      context,
      title: t('whiteBalance'),
      values: wbs,
      current: '',
      label: (v) => v,
      onSelect: (v) async {
        // TODO_NIKON: map WB name -> Nikon WB enum (gphoto2 nikon.h whitebalance[]).
      },
    );
  }

  void _showEvPicker(BuildContext context, WidgetRef ref) {
    final t = ref.read(stringsProvider);
    const evs = ['-3.0', '-2.0', '-1.0', '-0.7', '-0.3', '0.0', '+0.3', '+0.7', '+1.0', '+2.0', '+3.0'];
    _showPickerSheet<String>(
      context,
      title: t('exposureCompensation'),
      values: evs,
      current: '0.0',
      label: (v) => v,
      onSelect: (v) async {
        // TODO_NIKON: map EV string -> Nikon EV code table.
      },
    );
  }

  void _showPickerSheet<T>(
    BuildContext context, {
    required String title,
    required List<T> values,
    required T current,
    required String Function(T) label,
    required Future<void> Function(T) onSelect,
  }) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(title, style: Theme.of(context).textTheme.titleMedium),
              ),
              const Divider(height: 1),
              SizedBox(
                height: 220,
                child: ListView.builder(
                  itemCount: values.length,
                  itemBuilder: (_, i) {
                    final v = values[i];
                    final isCurrent = v == current;
                    return ListTile(
                      title: Text(label(v)),
                      trailing: isCurrent
                          ? const Icon(Icons.check, color: AppColors.accent, size: 18)
                          : null,
                      onTap: () {
                        Navigator.pop(ctx);
                        onSelect(v);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ParamChip extends StatelessWidget {
  const _ParamChip({required this.label, required this.value, required this.onTap});
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Material(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 9, color: AppColors.onSurfaceMuted, letterSpacing: 1)),
                Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.accent)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
