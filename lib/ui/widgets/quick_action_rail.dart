// Floating quick-action rail — one-tap toggles for the most-used assists.
//
// Vertical on phones/tablets (right edge), or horizontal on narrow portrait.
// Each button highlights when its corresponding assist is on.
library;

import 'package:flutter/material.dart';

import '../../models/monitor_assist_settings.dart';
import '../../utils/theme.dart';

class QuickActionRail extends StatelessWidget {
  const QuickActionRail({
    super.key,
    required this.onTogglePeaking,
    required this.onToggleZebra,
    required this.onToggleFalseColor,
    required this.onToggleLut,
    required this.onCapture,
    required this.onRecordToggle,
    required this.settings,
    this.horizontal = false,
  });

  final VoidCallback onTogglePeaking;
  final VoidCallback onToggleZebra;
  final VoidCallback onToggleFalseColor;
  final VoidCallback onToggleLut;
  final VoidCallback onCapture;
  final VoidCallback onRecordToggle;
  final MonitorAssistSettings settings;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      _ActionBtn(
        icon: Icons.blur_on,
        label: 'Peak',
        active: settings.peakingEnabled,
        activeColor: peakingColorValue(settings.peakingColor),
        onTap: onTogglePeaking,
      ),
      _ActionBtn(
        icon: Icons.waves,
        label: 'Zebra',
        active: settings.zebraEnabled,
        activeColor: AppColors.cyan,
        onTap: onToggleZebra,
      ),
      _ActionBtn(
        icon: Icons.palette_outlined,
        label: 'False',
        active: settings.falseColorEnabled,
        activeColor: AppColors.yellow,
        onTap: onToggleFalseColor,
      ),
      _ActionBtn(
        icon: Icons.tune_rounded,
        label: 'LUT',
        active: settings.lutActuallyApplied,
        activeColor: AppColors.accent,
        onTap: onToggleLut,
      ),
      const Divider(height: 1, indent: 8, endIndent: 8),
      _ActionBtn(
        icon: Icons.camera,
        label: 'Shoot',
        active: false,
        activeColor: AppColors.accent,
        onTap: onCapture,
      ),
      _ActionBtn(
        icon: Icons.fiber_manual_record,
        label: 'Rec',
        active: false,
        activeColor: AppColors.red,
        onTap: onRecordToggle,
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        border: Border(
          left: horizontal ? BorderSide.none : const BorderSide(color: AppColors.surfaceVariant, width: 0.5),
          top: horizontal ? const BorderSide(color: AppColors.surfaceVariant, width: 0.5) : BorderSide.none,
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: horizontal
          ? Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: children)
          : Column(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: children),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.active,
    required this.activeColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 22,
                color: active ? activeColor : AppColors.onSurfaceMuted,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 9,
                  color: active ? activeColor : AppColors.onSurfaceMuted,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
