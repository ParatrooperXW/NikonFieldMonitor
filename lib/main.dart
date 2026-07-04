import 'dart:async';

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

  runZonedGuarded(
    () async {
      try {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } catch (_) {}
      try {
        await WakelockPlus.enable();
      } catch (_) {}
      runApp(const ProviderScope(child: NikonFieldMonitorApp()));
    },
    (Object error, StackTrace stack) {
      debugPrint('Uncaught async error: $error\n$stack');
    },
  );
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
