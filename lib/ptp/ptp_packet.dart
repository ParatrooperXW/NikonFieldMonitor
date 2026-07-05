// PTP/IP packet encoding & decoding (Nikon variant).
//
// Nikon cameras use an older / variant PTP/IP protocol that differs from
// the PIMA 15740 standard in packet type numbering and payload layouts.
// This file implements the Nikon variant as reverse-engineered by gphoto2.
//
// Packet structure:
//   [4-byte length (uint32 LE, includes the 8-byte header)]
//   [4-byte type   (uint32 LE)]
//   [payload bytes...]
//
// Packet type values (Nikon variant, verified against gphoto ptpip docs):
//   0x00000001 Init_Command_Request   (host → camera)
//   0x00000002 Init_Command_Ack       (camera → host)
//   0x00000003 Init_Event_Request     (host → camera)
//   0x00000004 Init_Event_Ack         (camera → host)
//   0x00000005 Init_Fail              (either direction)
//   0x00000006 Cmd_Request            (host → camera)
//   0x00000007 Cmd_Response           (camera → host)
//   0x00000008 Event                  (camera → host)
//   0x00000009 Start_Data_Packet      (either direction)
//   0x0000000A Data_Packet            (either direction)
//   0x0000000B Cancel_Transaction     (host → camera)
//   0x0000000C End_Data_Packet        (either direction)
//
// References:
//   - gphoto2 PTP/IP docs: https://gphoto.github.io/doc/ptpip/
//   - gphoto2 camlibs/ptp2/ptpip.c
//   - Nikon CoolPix P1/P2/P3/P4/S6 reverse engineering
library;

import 'dart:typed_data';

import 'nikon_opcodes.dart';

/// PTP-IP packet type identifiers (Nikon variant).
abstract final class PtpIpPacketType {
  static const int initCommandReq = 0x00000001;
  static const int initCommandAck = 0x00000002;
  static const int initEventReq = 0x00000003;
  static const int initEventAck = 0x00000004;
  static const int initFail = 0x00000005;
  static const int cmdReq = 0x00000006;
  static const int cmdResponse = 0x00000007;
  static const int event = 0x00000008;
  static const int startData = 0x00000009;
  static const int data = 0x0000000A;
  static const int cancel = 0x0000000B;
  static const int endData = 0x0000000C;

  // Legacy / convenience aliases
  static const int initReq = initCommandReq;
  static const int initAck = initCommandAck;
  static const int eventReq = initEventReq;
  static const int eventAck = initEventAck;
  static const int req = cmdReq;
  static const int res = cmdResponse;
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
// PTP command / response payloads (Nikon PTP/IP variant)
// ==========================================================================
//
// NOTE: The Nikon variant does NOT use the standard PTP command/response
// blocks (with length prefix and type field). Instead it uses simpler
// payloads inside Cmd_Request / Cmd_Response packets:
//
// Cmd_Request payload:
//   [unknown: u32 LE]     — always 0x00000001
//   [opcode: u16 LE]
//   [transactionId: u32 LE]
//   [param1..N: u32 LE]   — as many as the operation needs (0..5)
//
// Cmd_Response payload:
//   [responseCode: u16 LE]
//   [transactionId: u32 LE]
//   [param1..N: u32 LE]   — variable number
//

/// Build a Cmd_Request payload (Nikon PTP/IP variant).
Uint8List buildCmdRequest({
  required int operationCode,
  required int transactionId,
  List<int> params = const [],
}) {
  final b = BytesBuilder();
  b.add(_u32le(1)); // unknown field, always 1
  b.add(_u16le(operationCode));
  b.add(_u32le(transactionId));
  for (final p in params) {
    b.add(_u32le(p));
  }
  return b.toBytes();
}

/// Parse a Cmd_Response payload (Nikon PTP/IP variant).
class PtpCmdResponse {
  PtpCmdResponse({
    required this.responseCode,
    required this.transactionId,
    required this.params,
  });
  final int responseCode;
  final int transactionId;
  final List<int> params;

  bool get isOk => responseCode == PtpResponse.ok;

  static PtpCmdResponse parse(Uint8List data) {
    if (data.length < 6) {
      throw FormatException('CmdResponse too short: ${data.length}B');
    }
    final bd = ByteData.sublistView(data);
    final code = bd.getUint16(0, Endian.little);
    final tx = bd.getUint32(2, Endian.little);
    final params = <int>[];
    var offset = 6;
    while (offset + 4 <= data.length) {
      params.add(bd.getUint32(offset, Endian.little));
      offset += 4;
    }
    return PtpCmdResponse(responseCode: code, transactionId: tx, params: params);
  }
}

// ==========================================================================
// Init packet payload builders
// ==========================================================================

/// Build an Init_Command_Request payload.
///
/// Wire layout (Nikon variant, per gphoto2):
///   [guid: 16 bytes]
///   [friendlyName: PTP string]
///     PTP string = [u8 length (num chars including null)] [u16 LE chars...] [u16 LE null]
///
/// NOTE: The Nikon variant does NOT include a protocolVersion field
/// at the end — adding one causes Init_Fail from the camera.
Uint8List buildInitReq(Uint8List guid, String friendlyName) {
  final b = BytesBuilder();
  if (guid.length != 16) {
    throw ArgumentError('guid must be 16 bytes, got ${guid.length}');
  }
  b.add(guid);
  b.add(_encodePtpString(friendlyName));
  return b.toBytes();
}

/// Parse the connection number / session ID from Init_Command_Ack payload.
///
/// Wire layout:
///   [connectionNumber: u32 LE]   — session ID to use for Init_Event_Request
///   [guid: 16 bytes]
///   [friendlyName: PTP string]
int parseInitAckConnectionNumber(Uint8List payload) {
  if (payload.length < 4) {
    throw FormatException('InitAck too short: ${payload.length}B');
  }
  return ByteData.sublistView(payload).getUint32(0, Endian.little);
}

/// Build an Init_Event_Request payload.
///
/// Wire layout (Nikon variant):
///   [connectionNumber: u32 LE]   — from Init_Command_Ack
Uint8List buildInitEventReq(int connectionNumber) {
  return _u32le(connectionNumber);
}

// ==========================================================================
// Helpers
// ==========================================================================

/// Encode a PTP string: [u8 len][u16 LE chars...][u16 LE null terminator].
/// Length byte counts the number of UTF-16 units INCLUDING the null.
Uint8List _encodePtpString(String s) {
  final b = BytesBuilder();
  final units = _utf16leUnits(s);
  b.addByte(units.length + 1); // +1 for null terminator unit
  for (final u in units) {
    b.add(_u16le(u));
  }
  b.add(_u16le(0)); // null terminator
  return b.toBytes();
}

List<int> _utf16leUnits(String s) {
  final units = <int>[];
  for (final c in s.codeUnits) {
    if (c <= 0xFFFF) {
      units.add(c);
    } else {
      // surrogate pair for code points above BMP
      final cp = c - 0x10000;
      units.add(0xD800 + (cp >> 10));
      units.add(0xDC00 + (cp & 0x3FF));
    }
  }
  return units;
}

Uint8List _u16le(int v) =>
    Uint8List(2)..[0] = v & 0xFF..[1] = (v >> 8) & 0xFF;
Uint8List _u32le(int v) =>
    Uint8List(4)
      ..[0] = v & 0xFF
      ..[1] = (v >> 8) & 0xFF
      ..[2] = (v >> 16) & 0xFF
      ..[3] = (v >> 24) & 0xFF;
