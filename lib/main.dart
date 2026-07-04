// App entry point.
//
// Initializes services, enables wakelock (so the monitor stays awake during
// long shoots), registers the native render bridge listeners, and routes to
// either the connection page or the live view page depending on state.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'state/providers.dart';
import 'ui/screens/connection_screen.dart';
import 'ui/screens/liveview_screen.dart';
import 'utils/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
  };
  // Lock to portrait-up + landscape for tablets; we handle rotation in-screen.
  try {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  } catch (_) {
    // Ignore orientation errors on unsupported devices
  }
  // Keep screen on while the app is running (critical for a monitor).
  try {
    await WakelockPlus.enable();
  } catch (_) {
    // Ignore wakelock errors
  }
  runApp(const ProviderScope(child: NikonFieldMonitorApp()));
}

class NikonFieldMonitorApp extends ConsumerWidget {
  const NikonFieldMonitorApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'NikonFieldMonitor',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: const _Router(),
    );
  }
}

class _Router extends ConsumerWidget {
  const _Router();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(cameraConnectionProvider);
    if (conn.isConnected) {
      return const LiveViewScreen();
    }
    return const ConnectionScreen();
  }
}
