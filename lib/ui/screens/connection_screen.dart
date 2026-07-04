// Connection screen — discover / manually enter a camera, view history.
//
// Tabs:
//   • Wi-Fi — broadcast discovery + manual IP entry
//   • USB  — list attached USB devices (Android only; iOS shows TODO note)
//   • History — saved connections
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/camera_state.dart';
import '../../native_bridge/usb_ptp_bridge.dart';
import '../../ptp/ptp_ip_client.dart';
import '../../state/providers.dart';
import '../../utils/theme.dart';

class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '15740');

  List<DiscoveredCamera> _discovered = [];
  bool _scanning = false;
  StreamSubscription<UsbPtpDevice>? _usbAttachSub;
  List<UsbPtpDevice> _usbDevices = const [];

  @override
  void initState() {
    super.initState();
    _refreshUsb();
    final usb = ref.read(usbPtpBridgeProvider);
    usb.startEventStream();
    _usbAttachSub = usb.deviceAttached.listen((_) => _refreshUsb());
  }

  @override
  void dispose() {
    _tab.dispose();
    _ipController.dispose();
    _portController.dispose();
    _usbAttachSub?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      final found = await discoverPtpIpCameras();
      setState(() => _discovered = found);
      if (mounted && found.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No cameras found on local network')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Discovery failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _refreshUsb() async {
    final usb = ref.read(usbPtpBridgeProvider);
    final has = await usb.hasUsbHost();
    if (!has) {
      setState(() => _usbDevices = const []);
      return;
    }
    final list = await usb.listUsbDevices();
    setState(() => _usbDevices = list);
  }

  Future<void> _connectWifi(String host, int port) async {
    final notifier = ref.read(cameraConnectionProvider.notifier);
    await notifier.connectWifi(host, port);
    final conn = ref.read(cameraConnectionProvider);
    if (conn.isConnected && mounted) {
      ref.read(savedConnectionsProvider.notifier).add(SavedConnection(
        id: 'wifi_${host}_$port',
        label: '${conn.properties.model} @ $host',
        transport: CameraTransport.wifi,
        host: host,
        port: port,
        lastUsed: DateTime.now(),
      ));
    } else if (conn.error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection failed: ${conn.error}')),
      );
    }
  }

  Future<void> _connectUsb(UsbPtpDevice d) async {
    final notifier = ref.read(cameraConnectionProvider.notifier);
    await notifier.connectUsb(d.deviceId);
    final conn = ref.read(cameraConnectionProvider);
    if (conn.isConnected) {
      ref.read(savedConnectionsProvider.notifier).add(SavedConnection(
        id: 'usb_${d.deviceId}',
        label: d.productName,
        transport: CameraTransport.usb,
        host: d.deviceId,
        lastUsed: DateTime.now(),
      ));
    } else if (conn.error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('USB connect failed: ${conn.error}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NikonFieldMonitor'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(icon: Icon(Icons.wifi), text: 'Wi-Fi'),
            Tab(icon: Icon(Icons.usb), text: 'USB'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _wifiTab(),
          _usbTab(),
          _historyTab(),
        ],
      ),
    );
  }

  Widget _wifiTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FilledButton.icon(
          icon: _scanning
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.radar),
          label: Text(_scanning ? 'Scanning…' : 'Auto-discover on local network'),
          onPressed: _scanning ? null : _scan,
        ),
        const SizedBox(height: 12),
        if (_discovered.isNotEmpty) ...[
          Text('Found ${_discovered.length} camera(s)', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final d in _discovered)
            Card(
              child: ListTile(
                leading: const Icon(Icons.camera_alt, color: AppColors.accent),
                title: Text(d.friendlyName ?? 'Camera'),
                subtitle: Text('${d.host.address}:${d.port}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _connectWifi(d.host.address, d.port),
              ),
            ),
          const Divider(height: 32),
        ],
        Text('Manual connection', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _ipController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Camera IP address',
            hintText: '192.168.0.10',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lan),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 120,
              child: TextField(
                controller: _portController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.link),
                label: const Text('Connect'),
                onPressed: () {
                  final host = _ipController.text.trim();
                  final port = int.tryParse(_portController.text.trim()) ?? 15740;
                  if (host.isEmpty) return;
                  _connectWifi(host, port);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          color: AppColors.surface,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Tip: enable “Wireless mobile utility” / “SnapBridge” off on the camera, '
              'and use the camera’s “Network → Connect to computer” Wi-Fi mode. '
              'Default PTP-IP port is 15740.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ],
    );
  }

  Widget _usbTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.usb, color: AppColors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'USB OTG (Android only)',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton.icon(
                onPressed: _refreshUsb,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _usbDevices.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No USB devices detected.\n'
                        'Connect a Nikon camera via OTG adapter and tap Refresh.\n\n'
                        'iOS note: USB-C cameras require MFi + External Accessory '
                        'framework — left as TODO.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      for (final d in _usbDevices)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.camera_alt, color: AppColors.accent),
                            title: Text(d.productName),
                            subtitle: Text(
                              'VID 0x${d.vendorId.toRadixString(16).padLeft(4, '0')}  '
                              'PID 0x${d.productId.toRadixString(16).padLeft(4, '0')}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _connectUsb(d),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _historyTab() {
    final conns = ref.watch(savedConnectionsProvider);
    if (conns.isEmpty) {
      return Center(
        child: Text('No saved connections yet.', style: Theme.of(context).textTheme.bodySmall),
      );
    }
    return ListView(
      children: [
        for (final c in conns.reversed)
          Dismissible(
            key: ValueKey(c.id),
            direction: DismissDirection.endToStart,
            background: Container(
              color: AppColors.red,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 24),
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            onDismissed: (_) =>
                ref.read(savedConnectionsProvider.notifier).remove(c.id),
            child: Card(
              child: ListTile(
                leading: Icon(
                  c.transport == CameraTransport.usb ? Icons.usb : Icons.wifi,
                  color: AppColors.accent,
                ),
                title: Text(c.label),
                subtitle: Text(
                  c.transport == CameraTransport.usb
                      ? 'USB device'
                      : '${c.host}:${c.port}',
                ),
                trailing: c.lastUsed == null
                    ? null
                    : Text(
                        '${c.lastUsed!.day}/${c.lastUsed!.month} '
                        '${c.lastUsed!.hour.toString().padLeft(2, '0')}:'
                        '${c.lastUsed!.minute.toString().padLeft(2, '0')}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                onTap: () {
                  if (c.transport == CameraTransport.wifi) {
                    _connectWifi(c.host, c.port);
                  } else {
                    // For USB history, just refresh and let user re-pick.
                    _refreshUsb();
                  }
                },
              ),
            ),
          ),
      ],
    );
  }
}
