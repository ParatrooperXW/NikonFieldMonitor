// PTP/IP client over TCP.
//
// Implements the PTP-IP transport on top of a raw TCP socket:
//   1. Connect TCP to camera (default port 15740).
//   2. Send InitReq -> expect InitAck (gives connectionId).
//   3. OpenSession (PTP op 0x1002) over the Req/Data/Res flow.
//   4. Operations are sent as Req packets; data is read from Data packets
//      and final status from Res packets.
//   5. Event channel is a second TCP connection that streams Event packets.
//
// This client is platform-agnostic (pure Dart sockets) so it works on both
// Android and iOS for the Wi-Fi path. USB OTG on Android goes through the
// native [UsbPtpService] + MethodChannel instead.
//
// References:
//   - gphoto2: camlibs/ptp2/ptpip.c
//   - libmtp: src/ptpip.c
//   - remoteyourcam-usb: PtpIpCamera.java (USB variant, same PTP framing)
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'nikon_opcodes.dart';
import 'ptp_packet.dart';

/// Phase indicator inside an operation Req packet.
abstract final class PtpDataPhase {
  static const int noData = 0;
  static const int sendData = 1; // host -> camera
  static const int receiveData = 2; // camera -> host
}

/// Result of a single PTP operation: response code + optional params + data.
class PtpOpResult {
  PtpOpResult(this.code, this.params, this.data);
  final int code; // PtpResponse.*
  final List<int> params;
  final Uint8List? data;

  bool get isOk => code == PtpResponse.ok;

  @override
  String toString() =>
      'PtpOpResult(code=0x${code.toRadixString(16)}, params=$params, '
      'data=${data?.length ?? 0}B)';
}

/// Discovered camera from a PTP/IP broadcast probe.
class DiscoveredCamera {
  DiscoveredCamera({
    required this.host,
    required this.port,
    required this.guid,
    this.friendlyName,
  });

  final InternetAddress host;
  final int port;
  final Uint8List guid; // 16 bytes
  final String? friendlyName;

  @override
  String toString() => 'DiscoveredCamera($friendlyName @ $host:$port)';
}

/// A live PTP/IP session with a Nikon camera.
///
/// One [PtpIpClient] owns two sockets: a command socket and an event socket.
/// Use [run] inside the operation methods; do not call concurrently — the
/// protocol is strictly request/response per transaction id.
class PtpIpClient {
  PtpIpClient({Uint8List? guid, String friendlyName = 'NikonFieldMonitor'})
    : guid = guid ?? _randomGuid(),
      friendlyName = friendlyName;

  final Uint8List guid; // 16 bytes identifying this client
  final String friendlyName;

  Socket? _cmdSocket;
  Socket? _evtSocket;
  StreamSubscription<Uint8List>? _evtSub;
  int _transactionId = 0;
  int _sessionId = 0;
  bool _isOpen = false;

  final _incoming = BytesBuilder();
  final _eventController = StreamController<PtpIpPacket>.broadcast();
  Stream<PtpIpPacket> get events => _eventController.stream;

  bool get isOpen => _isOpen;
  int get sessionId => _sessionId;

  /// Connect + InitReq/InitAck + OpenSession.
  Future<void> connect(InternetAddress host, [int port = 15740]) async {
    _cmdSocket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    _cmdSocket!.listen(_onCmdData, onError: _onCmdError, onDone: _onCmdDone);

    // InitReq
    final initReq = buildInitReq(guid, friendlyName);
    _cmdSocket!.add(PtpIpPacket(type: PtpIpPacketType.initReq, payload: initReq).encode());
    final initAck = await _waitForPacket(const Duration(seconds: 5));
    if (initAck.type != PtpIpPacketType.initAck) {
      throw PtpException('Expected InitAck, got type 0x${initAck.type.toRadixString(16)}');
    }
    // InitAck payload: [connectionId:u32]  (camera assigns this)
    // We don't strictly need it; OpenSession uses our own session id.

    // Open event channel (Nikon expects a second TCP connection for events).
    _evtSocket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    final evtReq = buildInitReq(guid, '${friendlyName}_evt');
    _evtSocket!.add(PtpIpPacket(type: PtpIpPacketType.eventReq, payload: evtReq).encode());
    _evtSub = _evtSocket!.listen(
      _onEvtData,
      onError: (Object e, StackTrace s) => _eventController.addError(e, s),
      onDone: () => _eventController.addError(SocketException('event channel closed'), StackTrace.current),
    );

    // OpenSession: standard PTP op 0x1002, param0 = session id.
    _sessionId = Random().nextInt(0xFFFFFF) + 1;
    final res = await operate(
      PtpOperation.openSession,
      dataPhase: PtpDataPhase.noData,
      params: [_sessionId],
    );
    if (!res.isOk) {
      throw PtpException('OpenSession failed: 0x${res.code.toRadixString(16)}');
    }
    _isOpen = true;
  }

  Future<void> close() async {
    if (!_isOpen) return;
    try {
      await operate(PtpOperation.closeSession, dataPhase: PtpDataPhase.noData);
    } catch (_) {/* ignore on shutdown */}
    _isOpen = false;
    await _evtSub?.cancel();
    await _evtSocket?.close();
    await _cmdSocket?.close();
    _eventController.close();
  }

  // ----- Operation API -----------------------------------------------------

  /// Execute a PTP operation with optional data phase.
  ///
  /// [dataPhase]:
  ///   - [PtpDataPhase.noData]      -> no data
  ///   - [PtpDataPhase.sendData]    -> host sends [outData] to camera
  ///   - [PtpDataPhase.receiveData] -> camera sends data to host (returned)
  Future<PtpOpResult> operate(
    int operationCode, {
    int dataPhase = PtpDataPhase.noData,
    List<int> params = const [],
    Uint8List? outData,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_cmdSocket == null) {
      throw PtpException('Not connected');
    }
    final tx = ++_transactionId;
    final reqPayload = buildOpRequest(
      transactionId: tx,
      dataPhase: dataPhase,
      operationCode: operationCode,
      params: params,
    );
    _cmdSocket!.add(PtpIpPacket(type: PtpIpPacketType.req, payload: reqPayload).encode());

    if (dataPhase == PtpDataPhase.sendData && outData != null) {
      _cmdSocket!.add(PtpIpPacket(type: PtpIpPacketType.data, payload: _dataPhasePayload(tx, outData)).encode());
    }

    Uint8List? receivedData;
    // Loop: we may receive a Data packet (receiveData phase) then a Res packet.
    while (true) {
      final pkt = await _waitForPacket(timeout);
      switch (pkt.type) {
        case PtpIpPacketType.data:
          // Strip the leading transactionId (u32) from Data payload.
          final r = PtpDataReader(ByteData.sublistView(pkt.payload));
          final _ = r.readUint32(); // transaction id
          receivedData = r.readBytes(pkt.payload.length - 4);
        case PtpIpPacketType.res:
          final r = PtpDataReader(ByteData.sublistView(pkt.payload));
          final respTx = r.readUint32();
          final code = r.readUint16();
          if (respTx != tx) {
            throw PtpException('Transaction mismatch: $respTx != $tx');
          }
          final ps = <int>[];
          while (r.remaining >= 4) {
            ps.add(r.readUint32());
          }
          return PtpOpResult(code, ps, receivedData);
        default:
          // ignore unexpected packet types (e.g. late event)
          break;
      }
    }
  }

  Uint8List _dataPhasePayload(int tx, Uint8List data) {
    final b = BytesBuilder();
    b.add(_u32le(tx));
    b.add(data);
    return b.toBytes();
  }

  // ----- Socket framing ----------------------------------------------------

  void _onCmdData(Uint8List chunk) {
    _incoming.add(chunk);
    _drainIncoming(_cmdSocket, _eventController);
  }

  void _onEvtData(Uint8List chunk) {
    // Event channel framing is identical to command channel.
    final b = BytesBuilder()..add(chunk);
    _drainBufferInto(b, _eventController);
  }

  void _onCmdError(Object e, StackTrace s) {
    _eventController.addError(e, s);
  }

  void _onCmdDone() {
    if (_isOpen) {
      _eventController.addError(SocketException('command channel closed by camera'), StackTrace.current);
    }
  }

  final _cmdCompleters = <Completer<PtpIpPacket>>[];

  Future<PtpIpPacket> _waitForPacket(Duration timeout) {
    final c = Completer<PtpIpPacket>();
    _cmdCompleters.add(c);
    final sub = events.listen((_) {});
    Timer(timeout, () {
      if (!c.isCompleted) {
        c.completeError(TimeoutException('PTP packet timeout', timeout));
      }
    });
    // The actual delivery is handled by _drainIncoming via _eventController? No:
    // command-channel packets are NOT routed to events stream; we route them
    // here instead.
    return c.future..whenComplete(sub.cancel);
  }

  void _drainIncoming(Socket? s, StreamController<PtpIpPacket> sink) {
    // _incoming accumulates bytes from command socket; we extract full packets
    // and complete the oldest waiter.
    final bytes = _incoming.toBytes();
    var consumed = 0;
    while (bytes.length - consumed >= 4) {
      final len = ByteData.sublistView(bytes, consumed, consumed + 4).getUint32(0, Endian.little);
      if (bytes.length - consumed < len) break; // wait for more
      final pktBytes = bytes.sublist(consumed, consumed + len);
      consumed += len;
      final pkt = PtpIpPacket.decode(pktBytes);
      if (_cmdCompleters.isNotEmpty) {
        final c = _cmdCompleters.removeAt(0);
        if (!c.isCompleted) c.complete(pkt);
      }
    }
    if (consumed > 0) {
      // rebuild _incoming with leftover
      final leftover = bytes.sublist(consumed);
      _incoming.clear();
      _incoming.add(leftover);
    }
  }

  void _drainBufferInto(BytesBuilder b, StreamController<PtpIpPacket> sink) {
    final bytes = b.toBytes();
    var consumed = 0;
    while (bytes.length - consumed >= 4) {
      final len = ByteData.sublistView(bytes, consumed, consumed + 4).getUint32(0, Endian.little);
      if (bytes.length - consumed < len) break;
      final pktBytes = bytes.sublist(consumed, consumed + len);
      consumed += len;
      sink.add(PtpIpPacket.decode(pktBytes));
    }
    b.clear();
    b.add(bytes.sublist(consumed));
  }
}

class PtpException implements Exception {
  PtpException(this.message);
  final String message;
  @override
  String toString() => 'PtpException: $message';
}

Uint8List _randomGuid() {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(16, (_) => r.nextInt(256)));
}

Uint8List _u32le(int v) =>
    Uint8List(4)
      ..[0] = v & 0xFF
      ..[1] = (v >> 8) & 0xFF
      ..[2] = (v >> 16) & 0xFF
      ..[3] = (v >> 24) & 0xFF;

/// Discover Nikon cameras on the local subnet by sending an InitReq probe
/// to the broadcast address on port 15740 and collecting InitAck replies.
///
/// NOTE: Dart sockets cannot always do true UDP broadcast receive on every
/// platform; on Android we may fall back to a native [MethodChannel]
/// discovery helper. This Dart implementation works when the OS allows
/// receiving broadcasts.
Future<List<DiscoveredCamera>> discoverPtpIpCameras({
  Duration timeout = const Duration(seconds: 3),
  int port = 15740,
}) async {
  final found = <DiscoveredCamera>[];
  final guid = _randomGuid();
  final probe = PtpIpPacket(
    type: PtpIpPacketType.initReq,
    payload: buildInitReq(guid, 'NikonFieldMonitor_probe'),
  ).encode();

  final interfaces = await NetworkInterface.list();
  for (final iface in interfaces) {
    for (final addr in iface.addresses) {
      if (addr.type != InternetAddressType.IPv4) continue;
      final parts = addr.address.split('.');
      if (parts.length != 4) continue;
      final bcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      sock.send(probe, InternetAddress(bcast), port);
      final completer = Completer<void>();
      sock.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = sock.receive();
          if (dg != null && dg.data.length >= 8) {
            final pkt = PtpIpPacket.decode(dg.data);
            if (pkt.type == PtpIpPacketType.initAck) {
              found.add(DiscoveredCamera(
                host: dg.address,
                port: dg.port,
                guid: guid,
                friendlyName: 'Nikon@${dg.address.address}',
              ));
            }
          }
        }
      });
      Timer(timeout, () {
        sock.close();
        if (!completer.isCompleted) completer.complete();
      });
      await completer.future;
    }
  }
  return found;
}
