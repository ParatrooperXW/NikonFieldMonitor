// PTP/IP client over TCP (Nikon variant).
//
// Implements the Nikon variant of PTP-IP on top of raw TCP sockets.
// This is NOT the PIMA 15740 standard — Nikon cameras (CoolPix / Z
// series with WT transmitters / built-in Wi-Fi) use an older / variant
// protocol with different packet type numbering and payload layouts.
//
// Connection flow:
//   1. Open command TCP socket → send Init_Command_Request
//   2. Receive Init_Command_Ack (gives connectionNumber)
//   3. Open event TCP socket → send Init_Event_Request (with connectionNumber)
//   4. Receive Init_Event_Ack
//   5. OpenSession via Cmd_Request / Cmd_Response
//
// Operation flow for NO data phase:
//   Host → Camera: Cmd_Request
//   Camera → Host: Cmd_Response
//
// Operation flow for RECEIVE data phase (camera → host):
//   Host → Camera: Cmd_Request
//   Camera → Host: Start_Data_Packet (tx id + total length)
//   Camera → Host: Data_Packet*  (one or more chunks)
//   Camera → Host: End_Data_Packet (final data + Cmd_Response at end)
//
// References:
//   - gphoto2 PTP/IP docs: https://gphoto.github.io/doc/ptpip/
//   - gphoto2: camlibs/ptp2/ptpip.c
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'nikon_opcodes.dart';
import 'ptp_packet.dart';

/// Phase indicator — how the PTP data phase is expected to go.
abstract final class PtpDataPhase {
  static const int noData = 0;
  static const int sendData = 1; // host → camera
  static const int receiveData = 2; // camera → host
}

/// Result of a single PTP operation.
class PtpOpResult {
  PtpOpResult(this.code, this.params, this.data);
  final int code;
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
  final Uint8List guid;
  final String? friendlyName;

  @override
  String toString() => 'DiscoveredCamera($friendlyName @ $host:$port)';
}

/// A live PTP/IP session with a Nikon camera.
///
/// Owns two sockets: command (request/response) and event (camera → host).
/// Operations must be serialized — the protocol is strictly request/response
/// per transaction id.
class PtpIpClient {
  PtpIpClient({Uint8List? guid, String friendlyName = 'NikonFieldMonitor'})
    : guid = guid ?? _randomGuid(),
      friendlyName = friendlyName;

  final Uint8List guid;
  final String friendlyName;

  Socket? _cmdSocket;
  Socket? _evtSocket;
  StreamSubscription<Uint8List>? _evtSub;
  int _transactionId = 0;
  int _connectionNumber = 0;
  int _sessionId = 0;
  bool _isOpen = false;

  final _incoming = BytesBuilder();
  final _evtIncoming = BytesBuilder();
  final _eventController = StreamController<PtpIpPacket>.broadcast();
  Stream<PtpIpPacket> get events => _eventController.stream;

  final _cmdPackets = <PtpIpPacket>[];
  final _cmdCompleters = <Completer<PtpIpPacket>>[];

  bool get isOpen => _isOpen;
  int get sessionId => _sessionId;

  /// Connect + init handshake + OpenSession.
  Future<void> connect(InternetAddress host, [int port = 15740]) async {
    // ---- command channel ----
    _cmdSocket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    _cmdSocket!.listen(_onCmdData, onError: _onCmdError, onDone: _onCmdDone);

    final initReq = buildInitReq(guid, friendlyName);
    _cmdSocket!.add(
      PtpIpPacket(type: PtpIpPacketType.initCommandReq, payload: initReq)
          .encode(),
    );

    final initPkt = await _waitForPacket(const Duration(seconds: 5));
    if (initPkt.type == PtpIpPacketType.initFail) {
      final errCode = initPkt.payload.length >= 4
          ? ByteData.sublistView(initPkt.payload).getUint32(0, Endian.little)
          : 0;
      throw PtpException(
        'InitFail received from camera (error=0x${errCode.toRadixString(16)})',
      );
    }
    if (initPkt.type != PtpIpPacketType.initCommandAck) {
      throw PtpException(
        'Expected InitCommandAck, got type 0x${initPkt.type.toRadixString(16)}',
      );
    }
    _connectionNumber = parseInitAckConnectionNumber(initPkt.payload);

    // ---- event channel ----
    _evtSocket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    final evtPackets = <PtpIpPacket>[];
    final evtCompleters = <Completer<PtpIpPacket>>[];
    _evtSub = _evtSocket!.listen(
      (Uint8List chunk) {
        _evtIncoming.add(chunk);
        _drainEvtBuffer(evtPackets, evtCompleters);
      },
      onError: (Object e, StackTrace s) => _eventController.addError(e, s),
      onDone: () => _eventController.addError(
        SocketException('event channel closed'),
        StackTrace.current,
      ),
    );

    final evtReq = buildInitEventReq(_connectionNumber);
    _evtSocket!.add(
      PtpIpPacket(type: PtpIpPacketType.initEventReq, payload: evtReq).encode(),
    );

    final evtAck = await _waitEvt(
      evtPackets,
      evtCompleters,
      const Duration(seconds: 5),
    );
    if (evtAck.type == PtpIpPacketType.initFail) {
      throw PtpException('Event channel InitFail received from camera');
    }
    if (evtAck.type != PtpIpPacketType.initEventAck) {
      throw PtpException(
        'Expected InitEventAck, got type 0x${evtAck.type.toRadixString(16)}',
      );
    }

    // Route future event packets to the public events stream.
    await _evtSub?.cancel();
    _evtIncoming.clear();
    _evtSub = _evtSocket!.listen(
      _onEvtData,
      onError: (Object e, StackTrace s) => _eventController.addError(e, s),
      onDone: () => _eventController.addError(
        SocketException('event channel closed'),
        StackTrace.current,
      ),
    );

    // ---- OpenSession ----
    _sessionId = Random().nextInt(0xFFFFFF) + 1;
    final res = await operate(
      PtpOperation.openSession,
      dataPhase: PtpDataPhase.noData,
      params: [_sessionId],
    );
    if (!res.isOk) {
      throw PtpException(
        'OpenSession failed: 0x${res.code.toRadixString(16)}',
      );
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

    final cmdPayload = buildCmdRequest(
      operationCode: operationCode,
      transactionId: tx,
      params: params,
    );
    _cmdSocket!.add(
      PtpIpPacket(type: PtpIpPacketType.cmdReq, payload: cmdPayload).encode(),
    );

    if (dataPhase == PtpDataPhase.sendData && outData != null) {
      final startPayload = BytesBuilder()
        ..add(_u32le(tx))
        ..add(_u32le(outData.length));
      _cmdSocket!.add(
        PtpIpPacket(
          type: PtpIpPacketType.startData,
          payload: startPayload.toBytes(),
        ).encode(),
      );
      _cmdSocket!.add(
        PtpIpPacket(
          type: PtpIpPacketType.data,
          payload: _dataPayload(tx, outData),
        ).encode(),
      );
      _cmdSocket!.add(
        PtpIpPacket(
          type: PtpIpPacketType.endData,
          payload: _dataPayload(tx, Uint8List(0)),
        ).encode(),
      );
    }

    final dataBuilder = BytesBuilder();
    while (true) {
      final pkt = await _waitForPacket(timeout);
      switch (pkt.type) {
        case PtpIpPacketType.startData:
          break;
        case PtpIpPacketType.data:
          if (pkt.payload.length >= 4) {
            dataBuilder.add(pkt.payload.sublist(4));
          }
          continue _nextPacket;
        case PtpIpPacketType.endData:
          final resp = _extractEndDataResponse(pkt.payload, dataBuilder);
          if (resp.transactionId != tx) {
            throw PtpException(
              'Transaction mismatch: ${resp.transactionId} != $tx',
            );
          }
          final data = dataBuilder.isEmpty ? null : dataBuilder.toBytes();
          return PtpOpResult(resp.responseCode, resp.params, data);
        case PtpIpPacketType.cmdResponse:
          final resp = PtpCmdResponse.parse(pkt.payload);
          if (resp.transactionId != tx) {
            throw PtpException(
              'Transaction mismatch: ${resp.transactionId} != $tx',
            );
          }
          return PtpOpResult(resp.responseCode, resp.params, null);
        default:
          break;
      }
      _nextPacket:;
    }
  }

  /// Find the Cmd_Response block at the end of an End_Data_Packet payload.
  ///
  /// End_Data_Packet payload: [tx:u32 LE] [data bytes] [Cmd_Response]
  ///
  /// Cmd_Response layout: [code:u16 LE] [tx:u32 LE] [params:u32 LE...]
  ///
  /// Strategy: scan backwards from the end trying different response sizes.
  /// The response always ends the payload. We know the transaction id
  /// should match, and the response code should be a known PTP response.
  PtpCmdResponse _extractEndDataResponse(
    Uint8List payload,
    BytesBuilder dataBuilder,
  ) {
    if (payload.length < 10) {
      // Min: tx(4) + code(2) + tx(2, but at least code+tx in response = 6)
      // Actually min total = tx(4) + response(code 2 + tx 4) = 10
      return PtpCmdResponse.parse(payload.sublist(4));
    }
    final bd = ByteData.sublistView(payload);

    // The response is at the END of the payload.
    // Response starts at some offset S >= 4.
    // Response length = payload.length - S.
    // Response = [code:2][tx:4][params:4*N]
    // So response length = 6 + 4*N, which means (payload.length - S - 6) % 4 == 0
    // Also the tx in response should be the same as the tx at start of payload.
    final payloadTx = bd.getUint32(0, Endian.little);

    // Try to find response by matching transaction id.
    // Scan from the end backwards, looking for a u32 that equals payloadTx
    // at position where it would be the transaction id in a response
    // (i.e., at offset S+2 from start of response).
    for (var respStart = payload.length - 6; respStart >= 4; respStart -= 4) {
      final respTx = bd.getUint32(respStart + 2, Endian.little);
      if (respTx == payloadTx) {
        // Found a matching tx id at the right position for a response.
        // Verify: response code looks reasonable (high byte = 0x20 for standard)
        final respCode = bd.getUint16(respStart, Endian.little);
        if ((respCode & 0xF000) == 0x2000 || respCode == 0x2001) {
          if (respStart > 4) {
            dataBuilder.add(payload.sublist(4, respStart));
          }
          return PtpCmdResponse.parse(payload.sublist(respStart));
        }
      }
    }

    // Fallback: assume response starts right after tx id (no data in EndData)
    return PtpCmdResponse.parse(payload.sublist(4));
  }

  Uint8List _dataPayload(int tx, Uint8List data) {
    final b = BytesBuilder();
    b.add(_u32le(tx));
    b.add(data);
    return b.toBytes();
  }

  // ----- Socket framing ----------------------------------------------------

  void _onCmdData(Uint8List chunk) {
    _incoming.add(chunk);
    _drainIncoming();
  }

  void _onEvtData(Uint8List chunk) {
    _evtIncoming.add(chunk);
    final bytes = _evtIncoming.toBytes();
    var consumed = 0;
    while (bytes.length - consumed >= 4) {
      final len = ByteData.sublistView(bytes, consumed, consumed + 4)
          .getUint32(0, Endian.little);
      if (bytes.length - consumed < len) break;
      final pktBytes = bytes.sublist(consumed, consumed + len);
      consumed += len;
      _eventController.add(PtpIpPacket.decode(pktBytes));
    }
    if (consumed > 0) {
      final leftover = bytes.sublist(consumed);
      _evtIncoming.clear();
      _evtIncoming.add(leftover);
    }
  }

  void _drainEvtBuffer(
    List<PtpIpPacket> pktBuf,
    List<Completer<PtpIpPacket>> completers,
  ) {
    final bytes = _evtIncoming.toBytes();
    var consumed = 0;
    while (bytes.length - consumed >= 4) {
      final len = ByteData.sublistView(bytes, consumed, consumed + 4)
          .getUint32(0, Endian.little);
      if (bytes.length - consumed < len) break;
      final pktBytes = bytes.sublist(consumed, consumed + len);
      consumed += len;
      final pkt = PtpIpPacket.decode(pktBytes);
      if (completers.isNotEmpty) {
        final c = completers.removeAt(0);
        if (!c.isCompleted) c.complete(pkt);
      } else {
        pktBuf.add(pkt);
      }
    }
    if (consumed > 0) {
      final leftover = bytes.sublist(consumed);
      _evtIncoming.clear();
      _evtIncoming.add(leftover);
    }
  }

  Future<PtpIpPacket> _waitEvt(
    List<PtpIpPacket> pktBuf,
    List<Completer<PtpIpPacket>> completers,
    Duration timeout,
  ) {
    if (pktBuf.isNotEmpty) {
      return Future.value(pktBuf.removeAt(0));
    }
    final c = Completer<PtpIpPacket>();
    completers.add(c);
    Timer(timeout, () {
      if (!c.isCompleted) {
        c.completeError(
          TimeoutException('Event channel packet timeout', timeout),
        );
        completers.remove(c);
      }
    });
    return c.future;
  }

  void _onCmdError(Object e, StackTrace s) {
    _eventController.addError(e, s);
  }

  void _onCmdDone() {
    if (_isOpen) {
      _eventController.addError(
        SocketException('command channel closed by camera'),
        StackTrace.current,
      );
    }
  }

  Future<PtpIpPacket> _waitForPacket(Duration timeout) {
    if (_cmdPackets.isNotEmpty) {
      return Future.value(_cmdPackets.removeAt(0));
    }
    final c = Completer<PtpIpPacket>();
    _cmdCompleters.add(c);
    Timer(timeout, () {
      if (!c.isCompleted) {
        c.completeError(
          TimeoutException('PTP packet timeout', timeout),
        );
        _cmdCompleters.remove(c);
      }
    });
    return c.future;
  }

  void _drainIncoming() {
    final bytes = _incoming.toBytes();
    var consumed = 0;
    while (bytes.length - consumed >= 4) {
      final len = ByteData.sublistView(bytes, consumed, consumed + 4)
          .getUint32(0, Endian.little);
      if (bytes.length - consumed < len) break;
      final pktBytes = bytes.sublist(consumed, consumed + len);
      consumed += len;
      final pkt = PtpIpPacket.decode(pktBytes);
      if (_cmdCompleters.isNotEmpty) {
        final c = _cmdCompleters.removeAt(0);
        if (!c.isCompleted) c.complete(pkt);
      } else {
        _cmdPackets.add(pkt);
      }
    }
    if (consumed > 0) {
      final leftover = bytes.sublist(consumed);
      _incoming.clear();
      _incoming.add(leftover);
    }
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

/// Discover PTP/IP cameras on the local subnet via UDP broadcast probe.
///
/// Sends an Init_Command_Request to the broadcast address of each IPv4
/// interface and collects Init_Command_Ack replies.
Future<List<DiscoveredCamera>> discoverPtpIpCameras({
  Duration timeout = const Duration(seconds: 3),
  int port = 15740,
}) async {
  final found = <DiscoveredCamera>[];
  final guid = _randomGuid();
  final probe = PtpIpPacket(
    type: PtpIpPacketType.initCommandReq,
    payload: buildInitReq(guid, 'NikonFieldMonitor_probe'),
  ).encode();

  final interfaces = await NetworkInterface.list();
  final futures = <Future<void>>[];

  for (final iface in interfaces) {
    for (final addr in iface.addresses) {
      if (addr.type != InternetAddressType.IPv4) continue;
      final parts = addr.address.split('.');
      if (parts.length != 4) continue;
      final bcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';

      futures.add(() async {
        try {
          final sock = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4,
            0,
          );
          sock.broadcastEnabled = true;
          sock.send(probe, InternetAddress(bcast), port);

          final timer = Timer(timeout, () {
            sock.close();
          });

          await for (final event in sock) {
            if (event == RawSocketEvent.read) {
              final dg = sock.receive();
              if (dg != null && dg.data.length >= 8) {
                final pkt = PtpIpPacket.decode(dg.data);
                if (pkt.type == PtpIpPacketType.initCommandAck) {
                  found.add(DiscoveredCamera(
                    host: dg.address,
                    port: dg.port,
                    guid: guid,
                    friendlyName: 'Nikon@${dg.address.address}',
                  ));
                }
              }
            }
          }
          timer.cancel();
        } catch (_) {
          // ignore interface failures
        }
      }());
    }
  }

  await Future.wait(futures, eagerError: false);
  return found;
}
