// LiveView screen — the main monitor page.
//
// Layout (landscape-first, also works portrait):
//   ┌────────────────────────────────────────────┬──────────┐
//   │  LiveView Texture (aspectFit, fullscreen)  │  Quick   │
//   │  + HUD overlay (fps/latency)               │  rail    │
//   │  + touch-to-focus                          │          │
//   ├────────────────────────────────────────────┴──────────┤
//   │  Parameter drawer (ISO / shutter / aperture / WB / EV)│
//   └────────────────────────────────────────────────────────┘
//
// Top-right "🎬 Assist" button opens the assist menu BottomSheet.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/camera_state.dart';
import '../../models/monitor_assist_settings.dart';
import '../../state/providers.dart';
import '../../utils/theme.dart';
import '../widgets/assist_menu_sheet.dart';
import '../widgets/hud_overlay.dart';
import '../widgets/parameter_drawer.dart';
import '../widgets/quick_action_rail.dart';

class LiveViewScreen extends ConsumerStatefulWidget {
  const LiveViewScreen({super.key});

  @override
  ConsumerState<LiveViewScreen> createState() => _LiveViewScreenState();
}

class _LiveViewScreenState extends ConsumerState<LiveViewScreen> {
  bool _liveStarted = false;
  bool _drawerExpanded = true;
  final _transformationController = TransformationController();
  Timer? _propPollTimer;

  @override
  void initState() {
    super.initState();
    _startLiveView();
  }

  @override
  void dispose() {
    _propPollTimer?.cancel();
    _transformationController.dispose();
    super.dispose();
  }

  Future<void> _startLiveView() async {
    final svc = ref.read(liveViewServiceProvider);
    final connNotifier = ref.read(cameraConnectionProvider.notifier);
    try {
      connNotifier.setPhase(ConnectionPhase.liveViewStarting);
      await svc.start();
      if (mounted) {
        setState(() => _liveStarted = true);
        connNotifier.setPhase(ConnectionPhase.liveViewActive);
        _startPropPolling();
      }
    } catch (e) {
      if (mounted) {
        connNotifier.setError('LiveView failed: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('LiveView failed: $e')),
        );
      }
    }
  }

  Future<void> _stopLiveView() async {
    _propPollTimer?.cancel();
    final svc = ref.read(liveViewServiceProvider);
    await svc.stop();
    await svc.releaseTexture();
    if (mounted) setState(() => _liveStarted = false);
  }

  void _startPropPolling() {
    // Poll CheckEvent + device props every 2s to keep the drawer in sync.
    _propPollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final conn = ref.read(connectionServiceProvider);
      try {
        await conn.checkEvent();
        // TODO_NIKON: parse DevicePropValue responses for ISO/shutter/etc.
        // For now we leave the drawer to manual entry until the property
        // enum tables from gphoto2 nikon.h are wired in.
      } on Exception {
        // ignore transient poll errors
      }
    });
  }

  void _onAssistSettingsChanged() {
    if (!_liveStarted) return;
    final svc = ref.read(liveViewServiceProvider);
    final settings = ref.read(assistSettingsProvider);
    final tid = svc.textureId;
    if (tid == null) return;
    final bridge = ref.read(renderBridgeProvider);
    bridge.updateAssistSettings(tid, settings.toBridgeMap());
    if (settings.lutActuallyApplied) {
      bridge.setLutActive(tid, settings.activeLutId);
    } else {
      bridge.setLutActive(tid, null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(cameraConnectionProvider);
    final telemetry = ref.watch(liveViewTelemetryProvider);
    final settings = ref.watch(assistSettingsProvider);
    final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: isPortrait
            ? _buildPortrait(conn, telemetry, settings)
            : _buildLandscape(conn, telemetry, settings),
      ),
    );
  }

  Widget _buildLandscape(
    CameraConnectionState conn,
    AsyncValue<LiveViewTelemetry> telemetry,
    MonitorAssistSettings settings,
  ) {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: _liveViewStack(conn, telemetry, settings)),
              QuickActionRail(
                onTogglePeaking: () => _toggle(
                  (s) => s.copyWith(peakingEnabled: !s.peakingEnabled),
                ),
                onToggleZebra: () => _toggle(
                  (s) => s.copyWith(zebraEnabled: !s.zebraEnabled),
                ),
                onToggleFalseColor: () => _toggle(
                  (s) => s.copyWith(falseColorEnabled: !s.falseColorEnabled),
                ),
                onToggleLut: () => _toggle(
                  (s) => s.copyWith(lutEnabled: !s.lutEnabled),
                ),
                onCapture: _capture,
                onRecordToggle: _toggleRecord,
                settings: settings,
              ),
            ],
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: SizedBox(
            height: _drawerExpanded ? 96 : 40,
            child: ParameterDrawer(
              expanded: _drawerExpanded,
              onToggleExpand: () => setState(() => _drawerExpanded = !_drawerExpanded),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPortrait(
    CameraConnectionState conn,
    AsyncValue<LiveViewTelemetry> telemetry,
    MonitorAssistSettings settings,
  ) {
    return Column(
      children: [
        Expanded(child: _liveViewStack(conn, telemetry, settings)),
        QuickActionRail(
          horizontal: true,
          onTogglePeaking: () => _toggle(
            (s) => s.copyWith(peakingEnabled: !s.peakingEnabled),
          ),
          onToggleZebra: () => _toggle(
            (s) => s.copyWith(zebraEnabled: !s.zebraEnabled),
          ),
          onToggleFalseColor: () => _toggle(
            (s) => s.copyWith(falseColorEnabled: !s.falseColorEnabled),
          ),
          onToggleLut: () => _toggle(
            (s) => s.copyWith(lutEnabled: !s.lutEnabled),
          ),
          onCapture: _capture,
          onRecordToggle: _toggleRecord,
          settings: settings,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: SizedBox(
            height: _drawerExpanded ? 96 : 40,
            child: ParameterDrawer(
              expanded: _drawerExpanded,
              onToggleExpand: () => setState(() => _drawerExpanded = !_drawerExpanded),
            ),
          ),
        ),
      ],
    );
  }

  Widget _liveViewStack(
    CameraConnectionState conn,
    AsyncValue<LiveViewTelemetry> telemetry,
    MonitorAssistSettings settings,
  ) {
    final svc = ref.read(liveViewServiceProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Top bar with camera info + assist button
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _topBar(conn),
        ),
        // LiveView texture (aspectFit, pinch-zoom + pan)
        GestureDetector(
          onTapUp: (d) => _handleTouchFocus(d, context),
          child: InteractiveViewer(
            transformationController: _transformationController,
            boundaryMargin: const EdgeInsets.all(double.infinity),
            minScale: 1.0,
            maxScale: 4.0,
            child: _liveViewTexture(svc.textureId),
          ),
        ),
        // HUD overlay (fps/latency)
        if (settings.hudVisible)
          Positioned(
            left: 8,
            bottom: 8,
            child: HudOverlay(
              telemetry: telemetry,
              connection: conn,
              settings: settings,
            ),
          ),
        // Safe-frame overlay
        if (settings.safeFrame != SafeFrame.none)
          Positioned.fill(child: _safeFrameOverlay(settings.safeFrame)),
      ],
    );
  }

  Widget _liveViewTexture(int? textureId) {
    if (textureId == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: 1920,
              height: 1080,
              child: Texture(textureId: textureId),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar(CameraConnectionState conn) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.black54,
      child: Row(
        children: [
          Icon(
            conn.transport == CameraTransport.usb ? Icons.usb : Icons.wifi,
            color: AppColors.accent,
            size: 18,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${conn.properties.model}  ${conn.properties.firmwareVersion}',
              style: const TextStyle(fontSize: 13, color: AppColors.onSurface),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.movie_creation_outlined, color: AppColors.accent),
            tooltip: 'Monitor assist',
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const AssistMenuSheet(),
            ).then((_) => _onAssistSettingsChanged()),
          ),
          IconButton(
            icon: const Icon(Icons.power_settings_new, color: AppColors.red),
            tooltip: 'Disconnect',
            onPressed: _disconnect,
          ),
        ],
      ),
    );
  }

  Widget _safeFrameOverlay(SafeFrame sf) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _SafeFramePainter(sf),
        child: const SizedBox.expand(),
      ),
    );
  }

  void _handleTouchFocus(TapUpDetails d, BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final size = renderBox.size;
    final local = d.localPosition;
    final nx = (local.dx / size.width).clamp(0.0, 1.0);
    final ny = (local.dy / size.height).clamp(0.0, 1.0);
    final conn = ref.read(connectionServiceProvider);
    conn.changeAfArea(nx, ny).then((_) {
      conn.afDrive();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('AF @ (${(nx * 100).round()}%, ${(ny * 100).round()}%)'),
            duration: const Duration(milliseconds: 600),
          ),
        );
      }
    });
  }

  void _toggle(MonitorAssistSettings Function(MonitorAssistSettings) updater) {
    final notifier = ref.read(assistSettingsProvider.notifier);
    final next = updater(ref.read(assistSettingsProvider));
    notifier.update(next);
    _onAssistSettingsChanged();
  }

  Future<void> _capture() async {
    final conn = ref.read(connectionServiceProvider);
    try {
      await conn.capture();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e')),
        );
      }
    }
  }

  bool _recording = false;
  Future<void> _toggleRecord() async {
    final conn = ref.read(connectionServiceProvider);
    try {
      if (_recording) {
        await conn.stopMovie();
      } else {
        await conn.startMovie();
      }
      setState(() => _recording = !_recording);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Record toggle failed: $e')),
        );
      }
    }
  }

  Future<void> _disconnect() async {
    await _stopLiveView();
    await ref.read(cameraConnectionProvider.notifier).disconnect();
  }
}

class _SafeFramePainter extends CustomPainter {
  _SafeFramePainter(this.sf);
  final SafeFrame sf;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xCCFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final center = Offset(size.width / 2, size.height / 2);

    void drawFrame(double w, double h) {
      final left = center.dx - w / 2;
      final top = center.dy - h / 2;
      canvas.drawRect(Rect.fromLTWH(left, top, w, h), paint);
    }

    switch (sf) {
      case SafeFrame.ratio16x9:
        final h = size.height * 0.9;
        drawFrame(h * 16 / 9, h);
      case SafeFrame.ratio2_39x1:
        final h = size.height * 0.9;
        drawFrame(h * 2.39, h);
      case SafeFrame.ratio4x3:
        final h = size.height * 0.9;
        drawFrame(h * 4 / 3, h);
      case SafeFrame.centerCross:
        canvas.drawLine(
          Offset(center.dx, 0),
          Offset(center.dx, size.height),
          paint,
        );
        canvas.drawLine(
          Offset(0, center.dy),
          Offset(size.width, center.dy),
          paint,
        );
      case SafeFrame.none:
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _SafeFramePainter old) => old.sf != sf;
}
