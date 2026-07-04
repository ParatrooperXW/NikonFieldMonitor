// PTP/IP packet encoding & decoding.
//
// PTP-IP runs over TCP. The protocol layers packets as:
//   [4-byte length (uint32 LE, includes itself)]
//   [4-byte type   (uint32 LE)]
//   [payload bytes...]
//
// Packet types per PIMA 15740 (PTP-IP), verified against gphoto2 ptpip.c:
//   0x00000001 InitReq
//   0x00000002 InitAck
//   0x00000003 InitFail
//   0x00000006 CmdReq    (was incorrectly named "Req")
//   0x0000000A CmdAck    (was missing — transport ack, not PTP response)
//   0x00000009 EventReq
//   0x00000007 EventAck
//   0x00000008 EventFail
//   0x0000000C Event
//   0x0000000B StartData
//   0x0000000D Data
//   0x0000000E Cancel
//   0x0000000F EndData   (carries the PTP Response at end of data phase)
//
// For a PTP operation with NO data phase:
//   Host → Camera: CmdReq  (contains full PTP command block)
//   Camera → Host: EndData (contains PTP Response as payload, no data)
//
// For a PTP operation WITH data IN phase (camera → host):
//   Host → Camera: CmdReq
//   Camera → Host: StartData  (includes transaction id + total length)
//   Camera → Host: Data  (possibly multiple chunks)
//   Camera → Host: EndData (contains PTP Response + final data chunk)
//
// References:
//   - gphoto2 camlibs/ptp2/ptpip.c
//   - libmtp / src/ptpip.c
//   - PIMA 15740:2000 (PTP-IP transport spec)
library;

import 'dart:typed_data';

import 'nikon_opcodes.dart';

/// PTP-IP packet type identifiers (correct values per PIMA 15740).
abstract final class PtpIpPacketType {
  static const int initReq = 0x00000001;
  static const int initAck = 0x00000002;
  static const int initFail = 0x00000003;
  static const int cmdReq = 0x00000006;
  static const int cmdAck = 0x0000000A;
  static const int eventReq = 0x00000009;
  static const int eventAck = 0x00000007;
  static const int eventFail = 0x00000008;
  static const int event = 0x0000000C;
  static const int startData = 0x0000000B;
  static const int data = 0x0000000D;
  static const int cancel = 0x0000000E;
  static const int endData = 0x0000000F;
  // Legacy aliases for backward compat (callers may still use these names)
  static const int req = cmdReq;
  static const int res = endData;
}

/// A single PTP-IP packet.
class PtpIpPacket {
  PtpIpPacket({required this.type, required this.payload});

  final int type;
  final Uint8List payload;

  /// Serialize to wire format: [length:u32][type:u32][payload...].
  Uint8List encode() {
    final totalLen = 8 + payload.length;
    final out = ByteData(totalLen);
    out.setUint32(0, totalLen, Endian.little);
    out.setUint32(4, type, Endian.little);
    out.buffer.asUint8List().setRange(8, totalLen, payload);
    return out.buffer.asUint8List();
  }

  /// Parse a complete packet from a buffer that already contains exactly
  /// `length` bytes (length field is NOT re-validated here).
  static PtpIpPacket decode(Uint8List buf) {
    if (buf.length < 8) {
      throw FormatException('PTP-IP packet too short: ${buf.length} bytes');
    }
    final bd = ByteData.sublistView(buf);
    final type = bd.getUint32(4, Endian.little);
    final payload = buf.sublist(8);
    return PtpIpPacket(type: type, payload: payload);
  }
}

/// Helper: extract the declared length of the next packet from a buffer.
/// Returns -1 if fewer than 4 bytes are available.
int ptpIpNextPacketLength(Uint8List buf) {
  if (buf.length < 4) return -1;
  return ByteData.sublistView(buf).getUint32(0, Endian.little);
}

// ==========================================================================
// PTP command / response blocks (not PTP-IP transport)
// ==========================================================================

/// Standard PTP command block layout (12 + N*4 bytes):
///   [length:u32 LE]         — total length of the block
///   [type:u16 LE]           — 1 = command
///   [operationCode:u16 LE]
///   [transactionId:u32 LE]
///   [param1..param5:u32 LE] — as many as needed (0..5)
///
/// Standard PTP response block layout:
///   [length:u32 LE]
///   [type:u16 LE]           — 2 = response
///   [responseCode:u16 LE]
///   [transactionId:u32 LE]
///   [param1..param5:u32 LE] — as many as needed

int _ptpBlockLength(int paramCount) => 12 + paramCount * 4;

/// Build a standard PTP command block (not the PTP-IP packet wrapper).
Uint8List buildPtpCommand({
  required int operationCode,
  required int transactionId,
  List<int> params = const [],
}) {
  final len = _ptpBlockLength(params.length);
  final bd = ByteData(len);
  bd.setUint32(0, len, Endian.little);
  bd.setUint16(4, 1, Endian.little); // type 1 = Command
  bd.setUint16(6, operationCode, Endian.little);
  bd.setUint32(8, transactionId, Endian.little);
  for (var i = 0; i < params.length; i++) {
    bd.setUint32(12 + i * 4, params[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

/// Parse a standard PTP response block.
class PtpResponseBlock {
  PtpResponseBlock({
    required this.responseCode,
    required this.transactionId,
    required this.params,
  });
  final int responseCode;
  final int transactionId;
  final List<int> params;

  bool get isOk => responseCode == PtpResponse.ok;

  static PtpResponseBlock parse(Uint8List data) {
    if (data.length < 12) {
      throw FormatException('PTP response block too short: ${data.length}B');
    }
    final bd = ByteData.sublistView(data);
    // final len = bd.getUint32(0, Endian.little); // total length
    // final type = bd.getUint16(4, Endian.little); // 2 = Response
    final code = bd.getUint16(6, Endian.little);
    final tx = bd.getUint32(8, Endian.little);
    final params = <int>[];
    var offset = 12;
    while (offset + 4 <= data.length) {
      params.add(bd.getUint32(offset, Endian.little));
      offset += 4;
    }
    return PtpResponseBlock(responseCode: code, transactionId: tx, params: params);
  }
}

// ==========================================================================
// PTP-IP packet payload builders
// ==========================================================================

/// Build an InitReq payload (PTP-IP session handshake).
///
/// Wire layout (verified against gphoto2 ptpip.c / ptpip_init_req):
///   [guid: 16 bytes]
///   [friendlyName: PTP string (u8 length + u16 UTF-16LE units)]
///   [protocolVersion: u32 = 0x00010000 (v1.0)]
Uint8List buildInitReq(Uint8List guid, String friendlyName) {
  final b = BytesBuilder();
  if (guid.length != 16) {
    throw ArgumentError('guid must be 16 bytes, got ${guid.length}');
  }
  b.add(guid);
  // PTP string: [u8 numUnits][u16 LE units...], last unit is null terminator
  // The length byte counts the number of UTF-16 units INCLUDING the null.
  final codeUnits = _utf16leUnits(friendlyName);
  b.addByte(codeUnits.length + 1); // +1 for null terminator
  for (final u in codeUnits) {
    b.add(_u16le(u));
  }
  b.add(_u16le(0)); // null terminator
  b.add(_u32le(0x00010000)); // protocol version 1.0
  return b.toBytes();
}

List<int> _utf16leUnits(String s) {
  final units = <int>[];
  for (final c in s.codeUnits) {
    if (c <= 0xFFFF) {
      units.add(c);
    } else {
      // surrogate pair
      final cp = c - 0x10000;
      units.add(0xD800 + (cp >> 10));
      units.add(0xDC00 + (cp & 0x3FF));
    }
  }
  return units;
}

/// Parse InitAck payload → (connectionNumber: u32).
///
/// Wire layout (gphoto2 ptpip.c ptpip_init_ack):
///   [connectionNumber: u32]
///   [guid: 16 bytes]
///   [friendlyName: PTP string]
///   [protocolVersion: u32]
int parseInitAckConnectionNumber(Uint8List payload) {
  if (payload.length < 4) {
    throw FormatException('InitAck too short: ${payload.length}B');
  }
  return ByteData.sublistView(payload).getUint32(0, Endian.little);
}

Uint8List _u16le(int v) =>
    Uint8List(2)..[0] = v & 0xFF..[1] = (v >> 8) & 0xFF;
Uint8List _u32le(int v) =>
    Uint8List(4)
      ..[0] = v & 0xFF
      ..[1] = (v >> 8) & 0xFF
      ..[2] = (v >> 16) & 0xFF
      ..[3] = (v >> 24) & 0xFF;
