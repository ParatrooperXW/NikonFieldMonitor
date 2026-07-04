// Nikon PTP operation codes & device property codes.
//
// References:
//   - gphoto2: camlibs/ptp2/nikon.h  (Nikon enablers / extended opcodes)
//   - gphoto2: camlibs/ptp2/ptp.h    (PTP standard opcodes & datatypes)
//   - digiCamControl source (Nikon XML over USB)
//   - remoteyourcam-usb (https://github.com/michaelzoech/remoteyourcam-usb)
//
// NOTE: Codes marked with TODO_NIKON are observed in captures but their
// exact payload schema is not yet confirmed against gphoto2/digiCamControl.
// Treat their handlers as best-effort and refine by diffing the source trees.
library;

import 'dart:typed_data';

/// Standard PTP operation codes (USB PIMA 15740 / MTP).
abstract final class PtpOperation {
  // Standard PTP operations
  static const int getDeviceInfo = 0x1001;
  static const int openSession = 0x1002;
  static const int closeSession = 0x1003;
  static const int getStorageIds = 0x1004;
  static const int getStorageInfo = 0x1005;
  static const int getObjectHandles = 0x1006;
  static const int getObjectInfo = 0x1008;
  static const int getObject = 0x1009;
  static const int deleteObject = 0x100B;
  static const int sendObjectInfo = 0x100C;
  static const int sendObject = 0x100D;
  static const int initiateCapture = 0x100E;
  static const int capture = 0x100F; // MTP
  static const int getDevicePropDesc = 0x1014;
  static const int getDevicePropValue = 0x1015;
  static const int setDevicePropValue = 0x1016;
  static const int resetDevice = 0x1017;
  static const int getDevicePropDescList = 0x1019;

  // Nikon vendor-specific operations (0x90xx / 0x92xx / 0x93xx / 0x96xx)
  static const int nikonCapture = 0x90C0; // Capture (Nikon-specific capture rec)
  static const int nikonCheckEvent = 0x90C7; // CheckEvent -> poll async events
  static const int nikonSetControlMode = 0x90C2; // 0=PC, 1=Camera
  static const int nikonAfDrive = 0x90C1; // Trigger autofocus
  static const int nikonDeviceReady = 0x90C8; // Poll device-ready after capture

  static const int nikonStartLiveView = 0x9201;
  static const int nikonEndLiveView = 0x9202;
  static const int nikonGetLiveViewImg = 0x9203;
  static const int nikonMfDrive = 0x9204; // MF drive (near/far)
  static const int nikonChangeAfArea = 0x9205; // Touch AF area (normalized)

  static const int nikonStartMovieRec = 0x920C;
  static const int nikonEndMovieRec = 0x920D;

  // TODO_NIKON: 0x9206 (GetLiveViewStatus) — verify against gphoto2 nikon.h
  // TODO_NIKON: 0x9207 (GetHdInfo)        — verify against gphoto2 nikon.h
  // TODO_NIKON: 0x921A (MgOff)            — verify against digiCamControl
}

/// Standard + Nikon device property codes (0xD0xx).
abstract final class PtpDeviceProp {
  static const int batteryLevel = 0x5001;
  static const int whiteBalance = 0x5005;
  static const int fNumber = 0x5007; // aperture
  static const int focalLength = 0x5008;
  static const int exposureTime = 0x500D; // shutter (shutter speed)
  static const int exposureBiasCompensation = 0x5010; // exposure compensation
  static const int exposureIndex = 0x500B; // ISO (ExposureIndex)
  static const int stillCaptureMode = 0x5013;

  // Nikon-specific 16-bit property codes used by Z-series
  static const int nikonExposureIndex = 0xD011; // ISO
  static const int nikonShutterSpeed = 0xD013; // shutter
  static const int nikonAperture = 0xD01A; // aperture
  static const int nikonWhiteBalance = 0xD01B; // WB
  static const int nikonExposureCompensation = 0xD016; // EV comp
  static const int nikonExposureProgramMode = 0xD012; // P/S/A/M
  static const int nikonLiveViewStatus = 0xD1A2; // TODO_NIKON confirm enum
  static const int nikonRecordingMedia = 0xD10B;

  // TODO_NIKON: 0xD0E5 (LiveViewStatus), 0xD1C0 (MovieRecording) — confirm
}

/// PTP response codes.
abstract final class PtpResponse {
  static const int ok = 0x2001;
  static const int generalError = 0x2002;
  static const int sessionNotOpen = 0x2003;
  static const int invalidTransactionId = 0x2004;
  static const int operationNotSupported = 0x2005;
  static const int parameterNotSupported = 0x2006;
  static const int deviceBusy = 0x200A;
  static const int accessDenied = 0x200F;
  static const int storeNotAvailable = 0x2013;
  static const int storeFull = 0x2014;
  static const int selfTestFailed = 0x2011;
  static const int incompleteTransfer = 0x2007;
  static const int invalidStorageId = 0x2008;
  static const int invalidObjectHandle = 0x2009;
  static const int invalidObjectFormatCode = 0x200B;
  static const int specificationByFormatUnsupported = 0x200C;
  static const int noValidObjectInfo = 0x200D;
  static const int invalidCodeFormat = 0x200E;
  static const int invalidParentObject = 0x201A;
  static const int invalidParameter = 0x201D;
  static const int sessionAlreadyOpened = 0x201E;
  static const int transactionCanceled = 0x201F;
  static const int specificationOfDestinationUnsupported = 0x2020;
  static const int devicePropNotSupported = 0x200A;
}

/// PTP data types (PIMA 15740:2000 Table 3).
abstract final class PtpDataType {
  static const int int8 = 0x0001;
  static const int uint8 = 0x0002;
  static const int int16 = 0x0003;
  static const int uint16 = 0x0004;
  static const int int32 = 0x0005;
  static const int uint32 = 0x0006;
  static const int int64 = 0x0007;
  static const int uint64 = 0x0008;
  static const int int128 = 0x0009;
  static const int uint128 = 0x000A;
  static const int aint8 = 0x4001;
  static const int auint8 = 0x4002;
  static const int aint16 = 0x4003;
  static const int auint16 = 0x4004;
  static const int aint32 = 0x4005;
  static const int auint32 = 0x4006;
  static const int aint64 = 0x4007;
  static const int auint64 = 0x4008;
  static const int aint128 = 0x4009;
  static const int auint128 = 0x400A;
  static const int str = 0xFFFF;
}

/// Helper to read/write little-endian PTP scalars from a byte stream.
class PtpDataReader {
  PtpDataReader(this.data);
  final ByteData data;
  int offset = 0;

  int get remaining => data.lengthInBytes - offset;

  int readUint8() {
    final v = data.getUint8(offset);
    offset += 1;
    return v;
  }

  int readUint16() {
    final v = data.getUint16(offset, Endian.little);
    offset += 2;
    return v;
  }

  int readUint32() {
    final v = data.getUint32(offset, Endian.little);
    offset += 4;
    return v;
  }

  String readString() {
    final n = readUint8();
    final codes = <int>[];
    for (var i = 0; i < n; i++) {
      codes.add(readUint16());
    }
    return String.fromCharCodes(codes);
  }

  Uint8List readBytes(int n) {
    final out = Uint8List.sublistView(data, offset, offset + n);
    offset += n;
    return out;
  }
}

class PtpDataWriter {
  PtpDataWriter();
  final BytesBuilder _b = BytesBuilder();

  Uint8List get bytes => _b.toBytes();

  void writeUint8(int v) => _b.addByte(v & 0xFF);
  void writeUint16(int v) =>
      _b.add(_u16(v));
  void writeUint32(int v) =>
      _b.add(_u32(v));

  void writeString(String s) {
    final units = s.codeUnits;
    writeUint8(units.length);
    for (final u in units) {
      writeUint16(u);
    }
  }

  void writeBytes(Uint8List b) => _b.add(b);
}

Uint8List _u16(int v) =>
    Uint8List(2)..[0] = v & 0xFF..[1] = (v >> 8) & 0xFF;
Uint8List _u32(int v) =>
    Uint8List(4)
      ..[0] = v & 0xFF
      ..[1] = (v >> 8) & 0xFF
      ..[2] = (v >> 16) & 0xFF
      ..[3] = (v >> 24) & 0xFF;
