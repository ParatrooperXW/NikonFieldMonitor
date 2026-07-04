// PTP/IP client over TCP.
//
// Implements the PTP-IP transport on top of a raw TCP socket:
//   1. Connect TCP to camera (default port 15740).
//   2. Send InitReq → expect InitAck (gives connectionNumber).
//   3. OpenSession (PTP op 0x1002) over CmdReq / EndData flow.
//   4. Operations are sent as CmdReq (containing a full PTP command block).
//   5. Response comes back inside an EndData packet (PTP response block).
//   6. Event channel is a second TCP connection that streams Event packets.
//
// Packet type values (PIMA 15740, verified against gphoto2 ptpip.c):
//   0x01 InitReq      0x02 InitAck      0x03 InitFail
//   0x06 CmdReq       0x0A CmdAck
//   0x09 EventReq     0x07 EventAck     0x08 EventFail   0x0C Event
//   0x0B StartData    0x0D Data         0x0E Cancel      0x0F EndData
//
// Operation flow for NO data phase (e.g. OpenSession):
//   Host → Camera: CmdReq (PTP command block as payload)
//   Camera → Host: EndData (PTP response block as payload)
//
// Operation flow for RECEIVE data phase (e.g. GetDevicePropValue):
//   Host → Camera: CmdReq
//   Camera → Host: StartData (transaction_id + total_data_len)
//   Camera → Host: Data*  (one or more chunks, first 4 bytes = transaction_id)
//   Camera → Host: EndData (PTP response + final data chunk)
//
// References:
//   - gphoto2: camlibs/ptp2/ptpip.c
//   - libmtp: src/ptpip.c
//   - PIMA 15740:2000 (Picture Transfer Protocol — IP Transport)
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

  // Buffered command-channel packets that arrived without a pending waiter.
  // Without this, Data + EndData arriving in the same TCP segment would
  // cause the EndData to be dropped → OpenSession timeout.
  final _cmdPackets = <PtpIpPacket>[];
  final _cmdCompleters = <Completer<PtpIpPacket>>[];

  bool get isOpen => _isOpen;
  int get sessionId => _sessionId;

  /// Connect + InitReq/InitAck + OpenSession.
  Future<void> connect(InternetAddress host, [int port = 15740]) async {
    // ---- command channel ----
    _cmdSocket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    // IMPORTANT: register listener BEFORE sending InitReq — otherwise the
    // InitAck can arrive before the listener is wired up and be lost.
    _cmdSocket!.listen(_onCmdData, onError: _onCmdError, onDone: _onCmdDone);

    final initReq = buildInitReq(guid, friendlyName);
    _cmdSocket!.add(PtpIpPacket(type: PtpIpPacketType.initReq, payload: initReq).encode());

    final initPkt = await _waitForPacket(const Duration(seconds: 5));
    if (initPkt.type == PtpIpPacketType.initFail) {
      throw PtpException('InitFail received from camera');
    }
    if (initPkt.type != PtpIpPacketType.initAck) {
      throw PtpException('Expected InitAck, got type 0x${initPkt.type.toRadixString(16)}');
    }
    _connectionNumber = parseInitAckConnectionNumber(initPkt.payload);

    // ---- event channel ----
    _evtSocket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    // IMPORTANT: listen BEFORE add — otherwise EventAck is lost.
    final evtPackets = <PtpIpPacket>[];
    final evtCompleters = <Completer<PtpIpPacket>>[];
    _evtSub = _evtSocket!.listen(
      (Uint8List chunk) {
        _evtIncoming.add(chunk);
        _drainEvtBuffer(evtPackets, evtCompleters);
      },
      onError: (Object e, StackTrace s) => _eventController.addError(e, s),
      onDone: () => _eventController.addError(
          SocketException('event channel closed'), StackTrace.current),
    );
    final evtReq = buildInitReq(guid, '${friendlyName}_evt');
    _evtSocket!.add(PtpIpPacket(type: PtpIpPacketType.eventReq, payload: evtReq).encode());

    // Wait for EventAck / EventFail on the event channel.
    final evtAck = await _waitEvt(evtPackets, evtCompleters, const Duration(seconds: 5));
    if (evtAck.type == PtpIpPacketType.eventFail) {
      throw PtpException('EventFail received from camera');
    }
    if (evtAck.type != PtpIpPacketType.eventAck) {
      throw PtpException('Expected EventAck, got type 0x${evtAck.type.toRadixString(16)}');
    }

    // After EventAck, route future event packets to the public events stream.
    // (The buffered packets and completer list are no longer needed for ack,
    // but we keep draining into _eventController for live events.)
    // We re-subscribe with a clean handler that forwards everything.
    await _evtSub?.cancel();
    _evtIncoming.clear();
    _evtSub = _evtSocket!.listen(
      _onEvtData,
      onError: (Object e, StackTrace s) => _eventController.addError(e, s),
      onDone: () => _eventController.addError(
          SocketException('event channel closed'), StackTrace.current),
    );

    // ---- OpenSession ----
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
  ///   - [PtpDataPhase.noData]      → no data phase
  ///   - [PtpDataPhase.sendData]    → host sends [outData] to camera
  ///   - [PtpDataPhase.receiveData] → camera sends data to host (returned)
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

    // Build the PTP command block (standard PTP command, NOT PTP-IP specific).
    final cmdBlock = buildPtpCommand(
      operationCode: operationCode,
      transactionId: tx,
      params: params,
    );
    // Wrap it inside a CmdReq PTP-IP packet.
    _cmdSocket!.add(PtpIpPacket(type: PtpIpPacketType.cmdReq, payload: cmdBlock).encode());

    if (dataPhase == PtpDataPhase.sendData && outData != null) {
      // For send-data: we send StartData + Data chunks + EndData.
      // Nikon PTP-IP uses the same pattern as gphoto2 ptpip.c.
      final startPayload = BytesBuilder()
        ..add(_u32le(tx))
        ..add(_u32le(outData.length));
      _cmdSocket!.add(PtpIpPacket(
        type: PtpIpPacketType.startData,
        payload: startPayload.toBytes(),
      ).encode());
      _cmdSocket!.add(PtpIpPacket(
        type: PtpIpPacketType.data,
        payload: _dataPayload(tx, outData),
      ).encode());
      // EndData with 0 data bytes and PTP response expected from camera
      // (camera sends back EndData containing the PTP response).
    }

    // Receive loop: collect Data packets until EndData arrives.
    final dataBuilder = BytesBuilder();
    while (true) {
      final pkt = await _waitForPacket(timeout);
      switch (pkt.type) {
        case PtpIpPacketType.startData:
          // ignore — we already know data is coming
          break;
        case PtpIpPacketType.data:
          // Payload layout: [transactionId:u32][data...]
          if (pkt.payload.length >= 4) {
            dataBuilder.add(pkt.payload.sublist(4));
          }
        case PtpIpPacketType.endData:
          // Payload layout: [transactionId:u32][data...][PTP response block]
          // The PTP response block is at the END of the payload.
          // We need to find it. The PTP response block starts with length u32.
          final resp = _extractEndDataResponse(pkt.payload, dataBuilder);
          if (resp.transactionId != tx) {
            throw PtpException(
              'Transaction mismatch: ${resp.transactionId} != $tx');
          }
          final data = dataBuilder.isEmpty ? null : dataBuilder.toBytes();
          return PtpOpResult(resp.responseCode, resp.params, data);
        case PtpIpPacketType.cmdAck:
          // Transport ack — ignore, we're waiting for EndData.
          break;
        default:
          // ignore unexpected packet types
          break;
      }
    }
  }

  /// Extract the PTP response block from the tail of an EndData payload,
  /// and prepend any data bytes before it to [dataBuilder].
  ///
  /// EndData payload layout (PIMA 15740):
  ///   [transactionId: u32 LE]
  ///   [data bytes: variable]
  ///   [PTP response block: starts with length u32 LE]
  ///
  /// To find the response block we work backwards: the last N bytes where
  /// N is the value at the last -N position. Since the response block's
  /// first field is its own length (u32 LE), and the response always ends
  /// the payload, we can read the length from `payload.length - 12` at
  /// minimum (response is at least 12 bytes: len(4)+type(2)+code(2)+tx(4)).
  PtpResponseBlock _extractEndDataResponse(Uint8List payload, BytesBuilder dataBuilder) {
    if (payload.length < 16) {
      // Minimum: tx(4) + response(12) = 16 bytes
      return PtpResponseBlock.parse(payload.sublist(4));
    }
    // The PTP response block is at the end of the payload.
    // We read the length from the 4 bytes starting at the position where
    // the response starts. But we don't know that position.
    // Strategy: the response is the last structured block; its own length
    // field tells us how many bytes it occupies. So we scan backwards from
    // the end looking for a valid length.
    //
    // Simpler approach used by gphoto2 / libmtp:
    //   response_start = payload.length - response_len
    // where response_len is read from `payload + payload.length - 12`
    // …but that assumes response has exactly 2 params (20 bytes).
    //
    // Most robust: read the last 4 bytes of the tx+data prefix to find
    // where response starts. Since response starts with its length, and
    // response.length + response_start == payload.length, we have:
    //   response_start = payload.length - response.length
    // We can't read response.length without knowing where it starts.
    //
    // Standard approach (gphoto2 ptpip.c ptpip_wait_for_response):
    // The EndData payload is:
    //   [transaction_id:4] [data] [response block]
    // and the response block is found by scanning forward from offset 4
    // for the PTP response type 0x0002 at offset 4 of the block.
    //
    // Simplest heuristic that works for all Nikon no-data operations:
    //   response block starts at offset 4 (no data in EndData for no-data ops).
    // For receive-data ops, we accumulate via Data packets and EndData
    // only carries the final (possibly zero-length) data chunk + response.
    //
    // To handle both cases, we look for the response block by trying
    // progressively earlier positions. The response block always:
    //   - starts with u32 length L
    //   - has length >= 12
    //   - at offset 4 has type == 2 (Response)
    //   - ends at payload.length

    for (var start = 4; start <= payload.length - 12; start++) {
      final bd = ByteData.sublistView(payload, start);
      final len = bd.getUint32(0, Endian.little);
      if (len < 12 || len > payload.length - start) continue;
      final type = bd.getUint16(4, Endian.little);
      if (type != 2) continue; // 2 = PTP Response block
      // Found the response block
      if (start > 4) {
        // There's data between tx id and response
        dataBuilder.add(payload.sublist(4, start));
      }
      return PtpResponseBlock.parse(payload.sublist(start, start + len));
    }
    // Fallback: assume response starts right after tx id (no data in EndData)
    return PtpResponseBlock.parse(payload.sublist(4));
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

  void _drainEvtBuffer(List<PtpIpPacket> pktBuf, List<Completer<PtpIpPacket>> completers) {
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
        c.completeError(TimeoutException('Event channel packet timeout', timeout));
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
        SocketException('command channel closed by camera'), StackTrace.current);
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
        c.completeError(TimeoutException('PTP packet timeout', timeout));
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

/// Discover PTP/IP cameras on the local subnet via UDP broadcast InitReq.
///
/// NOTE: Dart sockets cannot always do true UDP broadcast receive on every
/// platform; on Android we may fall back to a native helper.
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
