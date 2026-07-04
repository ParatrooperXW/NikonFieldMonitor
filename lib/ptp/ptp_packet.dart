// PTP/IP packet encoding & decoding.
//
// PTP-IP runs over TCP. The protocol layers packets as:
//   [4-byte length (uint32 LE, includes itself)]
//   [4-byte type   (uint32 LE)]
//   [payload bytes...]
//
// Packet types per PIMA 15740-4 / Nikon implementation:
//   0x00000001 InitReq
//   0x00000005 InitAck
//   0x00000002 InitFail
//   0x00000006 Req
//   0x00000007 Data
//   0x00000008 Res
//   0x00000009 EventReq
//   0x0000000A Event
//
// References:
//   - gphoto2 camlibs/ptp2/ptpip.c
//   - libmtp / ptpip.c
//   - remoteyourcam-usb PtpIpTransaction
library;

import 'dart:typed_data';

/// PTP-IP packet type identifiers.
abstract final class PtpIpPacketType {
  static const int initReq = 0x00000001;
  static const int initAck = 0x00000005;
  static const int initFail = 0x00000002;
  static const int req = 0x00000006;
  static const int data = 0x00000007;
  static const int res = 0x00000008;
  static const int eventReq = 0x00000009;
  static const int event = 0x0000000A;
  static const int probeReq = 0x0000000B;
  static const int probeAck = 0x0000000C;
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

/// Build an InitReq payload (PTP-IP session handshake).
/// Wire layout (see libmtp ptpip.c ptpip_init_req):
///   [guid: 16 bytes]
///   [friendlyName: ptp-str]
///   [protocolVersion: u32 = 0x00010000]
Uint8List buildInitReq(Uint8List guid, String friendlyName) {
  final b = BytesBuilder();
  if (guid.length != 16) {
    throw ArgumentError('guid must be 16 bytes, got ${guid.length}');
  }
  b.add(guid);
  // ptp-str: [u8 len][u16 units...]
  final units = friendlyName.codeUnits;
  b.addByte(units.length & 0xFF);
  for (final u in units) {
    b.add(_u16le(u));
  }
  b.add(_u32le(0x00010000)); // protocol version 1.0
  return b.toBytes();
}

/// Build a Req packet payload (operation request).
/// Wire layout (PTP-IP Req packet):
///   [transactionId: u32]
///   [dataPhase: u32]   (0 = no data, 1 = data out, 2 = data in)
///   [operationCode: u16]
///   [p0..p4: u32 each]  (only as many as provided)
Uint8List buildOpRequest({
  required int transactionId,
  required int dataPhase,
  required int operationCode,
  List<int> params = const [],
}) {
  final b = BytesBuilder();
  b.add(_u32le(transactionId));
  b.add(_u32le(dataPhase));
  b.add(_u16le(operationCode));
  for (final p in params) {
    b.add(_u32le(p));
  }
  return b.toBytes();
}

Uint8List _u16le(int v) =>
    Uint8List(2)..[0] = v & 0xFF..[1] = (v >> 8) & 0xFF;
Uint8List _u32le(int v) =>
    Uint8List(4)
      ..[0] = v & 0xFF
      ..[1] = (v >> 8) & 0xFF
      ..[2] = (v >> 16) & 0xFF
      ..[3] = (v >> 24) & 0xFF;
