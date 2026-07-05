// Nikon PTP operation codes & device property codes.
//
// References:
//   - gphoto2: camlibs/ptp2/nikon.h  (Nikon enablers / extended opcodes)
//   - gphoto2: camlibs/ptp2/ptp.h    (PTP standard opcodes & datatypes)
//   - digiCamControl source (Nikon XML over USB)
//   - remoteyourcam-usb (https://github.com/michaelzoech/remoteyourcam-usb)
//   - Nikon D5300 PTP/IP device info: https://dethcount.github.io/ptpip-d5300/
//   - Nikon COOLPIX A1000 reverse engineering: https://lilting.ch/articles/
//       nikon-coolpix-a1000-pc-connection
//
// Vendor extension ranges:
//   0x90xx - Nikon capture / device control operations
//   0x92xx - Nikon live view / movie operations
//   0xD0xx - Nikon device property codes (Z-series / newer DSLRs)
//   0x50xx - Standard PTP device property codes
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
  // Verified against gphoto2 nikon.h and D5300 PTP/IP device info
  static const int nikonInitiateCaptureRecInSdram = 0x90C0; // Capture to SDRAM
  static const int nikonAfDrive = 0x90C1; // Trigger autofocus
  static const int nikonChangeCameraMode = 0x90C2; // 0=PC, 1=Camera
  static const int nikonDeleteImagesInSdram = 0x90C5;
  static const int nikonGetLargeThumb = 0x90C6;
  static const int nikonGetEvent = 0x90C7; // CheckEvent -> poll async events
  static const int nikonDeviceReady = 0x90C8; // Poll device-ready after capture
  static const int nikonSetPreWbData = 0x90C9;
  static const int nikonGetVendorPropCodes = 0x90CA;
  static const int nikonAfAndCaptureRecInSdram = 0x90CB; // AF + capture in SDRAM
  static const int nikonAfCaptureSdram = 0x90CB; // alias
  static const int nikonGetPicCtrlData = 0x90CC;
  static const int nikonSetPicCtrlData = 0x90CD;
  static const int nikonDeleteCustomPicCtrl = 0x90CE;
  static const int nikonGetPicCtrlCapability = 0x90CF;

  static const int nikonStartLiveView = 0x9201;
  static const int nikonEndLiveView = 0x9202;
  static const int nikonGetLiveViewImage = 0x9203;
  static const int nikonGetLiveViewImg = 0x9203; // alias (legacy name)
  static const int nikonMfDrive = 0x9204; // MF drive (near/far)
  static const int nikonChangeAfArea = 0x9205; // Touch AF area (normalized)
  static const int nikonAfDriveCancel = 0x9206;
  static const int nikonInitiateCaptureRecInMedia = 0x9207; // Capture to card
  static const int nikonGetVendorStorageIds = 0x9208;
  static const int nikonStartMovieRecInCard = 0x920A;
  static const int nikonStartMovieRec = 0x920A; // alias
  static const int nikonEndMovieRec = 0x920B;
  static const int nikonTerminateCapture = 0x920C;
  static const int nikonGetPartialObjectHighSpeed = 0x920D;
  static const int nikonSetTransferListLock = 0x920E;
  static const int nikonGetTransferList = 0x920F;
  static const int nikonNotifyFileAcquisitionStart = 0x9210;
  static const int nikonNotifyFileAcquisitionEnd = 0x9211;
  static const int nikonGetSpecificSizeObject = 0x9212;

  // MTP / PTP object property operations (0x98xx)
  static const int nikonGetObjectPropsSupported = 0x9801;
  static const int nikonGetObjectPropDesc = 0x9802;
  static const int nikonGetObjectPropValue = 0x9803;
  static const int nikonGetObjectPropList = 0x9805;

  // Legacy aliases (kept for backward compat)
  static const int nikonCapture = nikonInitiateCaptureRecInSdram;
  static const int nikonCheckEvent = nikonGetEvent;
  static const int nikonSetControlMode = nikonChangeCameraMode;
}

/// Standard + Nikon device property codes.
///
/// Standard PTP properties live in the 0x50xx range; Nikon vendor
/// properties start at 0xD000 (older DSLRs) and 0xD100 / 0xD2xx (Z-series
/// and newer models with 32-bit extended property support).
///
/// Source: gphoto2 nikon.h + D5300 PTP/IP device info enumeration
abstract final class PtpDeviceProp {
  // ---- Standard PTP properties (0x50xx) ----
  static const int batteryLevel = 0x5001; // 0x5001 = BatteryLevel
  static const int imageSize = 0x5003; // 0x5003 = ImageSize
  static const int whiteBalance = 0x5005; // 0x5005 = WhiteBalance
  static const int fNumber = 0x5007; // 0x5007 = FNumber (aperture)
  static const int focalLength = 0x5008; // 0x5008 = FocalLength
  static const int focusMode = 0x500A;
  static const int focusMeteringMode = 0x500A; // alias
  static const int flashMode = 0x500C;
  static const int exposureIndex = 0x500B; // ISO
  static const int exposureTime = 0x500D; // shutter speed
  static const int exposureProgramMode = 0x500E;
  static const int exposureBiasCompensation = 0x5010;
  static const int dateTime = 0x5011;
  static const int stillCaptureMode = 0x5013;
  static const int burstNumber = 0x5018;

  // ---- Nikon vendor properties (0xD0xx - D5300 / CoolPix era) ----
  static const int nikonWBTuneAuto = 0xD017;
  static const int nikonWBTuneIncandescent = 0xD018;
  static const int nikonWBTuneFluorescent = 0xD019;
  static const int nikonWBTuneSunny = 0xD01A;
  static const int nikonWBTuneFlash = 0xD01B;
  static const int nikonWBTuneCloudy = 0xD01C;
  static const int nikonWBTuneShade = 0xD01D;
  static const int nikonWBPresetDataNo = 0xD01F;
  static const int nikonWBPresetDataValue0 = 0xD025;
  static const int nikonWBPresetDataValue1 = 0xD026;
  static const int nikonColorSpace = 0xD032;
  static const int nikonResetCustomSetting = 0xD045;
  static const int nikonISOAutoControl = 0xD054;
  static const int nikonExposureEVStep = 0xD056;
  static const int nikonAfAtLiveView = 0xD05D;
  static const int nikonAutoOffTime = 0xD066;
  static const int nikonExposureDelay = 0xD06A;
  static const int nikonNoiseReduction = 0xD06B;
  static const int nikonNumberingMode = 0xD06C;
  static const int nikonNoiseReductionHiIso = 0xD070;
  static const int nikonBracketingType = 0xD078;
  static const int nikonEnableShutter = 0xD07A;
  static const int nikonCommentString = 0xD080;
  static const int nikonEnableComment = 0xD081;
  static const int nikonOrientationSensorMode = 0xD082;
  static const int nikonMovieRecordScreenSize = 0xD090;
  static const int nikonEnableBracketing = 0xD0B0;
  static const int nikonAEBracketingStep = 0xD0B1;
  static const int nikonAEBracketingCount = 0xD0B2;
  static const int nikonWBBracketingStep = 0xD0B3;
  static const int nikonLensId = 0xD0D0;
  static const int nikonLensSort = 0xD0D1;
  static const int nikonLensType = 0xD0D2;
  static const int nikonLensFocalMin = 0xD0D3;
  static const int nikonLensFocalMax = 0xD0D4;
  static const int nikonLensApertureMin = 0xD0D5;
  static const int nikonLensApertureMax = 0xD0D6;
  static const int nikonAutoDistortion = 0xD0E8;
  static const int nikonSceneMode = 0xD0E9;
  static const int nikonShutterSpeed2 = 0xD0F0;
  static const int nikonExternalDCIn = 0xD0F2;
  static const int nikonWarningStatus = 0xD0F2 + 4;
  static const int nikonAFLockStatus = 0xD0F4;
  static const int nikonAELockStatus = 0xD0F5;
  static const int nikonFocusArea = 0xD0F8;
  static const int nikonFlexibleProgram = 0xD0F9;
  static const int nikonRecordingMedia = 0xD10B; // was D10B - verify
  static const int nikonOrientation = 0xD0E2;
  static const int nikonExternalSpeedLightExist = 0xD120;
  static const int nikonExternalSpeedLightStatus = 0xD121;
  static const int nikonExternalSpeedLightSort = 0xD122;
  static const int nikonFlashCompensation = 0xD124;
  static const int nikonNewExternalSpeedLightMode = 0xD125;
  static const int nikonInternalFlashCompensation = 0xD126;
  static const int nikonActiveDLighting = 0xD14E;
  static const int nikonWBTuneFluorescentType = 0xD14F;
  static const int nikonAFModeSelect = 0xD161;
  static const int nikonAFSubLight = 0xD163;
  static const int nikonISOAutoShutterTime = 0xD164;
  static const int nikonInternalFlashMode = 0xD167;
  static const int nikonISOAutoSetting = 0xD16A;
  static const int nikonISOAutoHighLimit = 0xD183;
  static const int nikonLiveViewStatus = 0xD1A2;
  static const int nikonLiveViewImageZoomRatio = 0xD1A3;
  static const int nikonLiveViewProhibitionCondition = 0xD1A4;
  static const int nikonExposureDisplayStatus = 0xD1B0;
  static const int nikonExposureIndicateStatus = 0xD1B1;
  static const int nikonInfoDisplayErrorStatus = 0xD1B2;
  static const int nikonExposureIndicateLightup = 0xD1B3;
  static const int nikonInternalFlashPopup = 0xD1C0;
  static const int nikonInternalFlashStatus = 0xD1C1;
  static const int nikonActivePicCtrlItem = 0xD1E0;
  static const int nikonChangePicCtrlItem = 0xD1E1;

  // ---- Z-series / newer Nikon 32-bit properties (0xD2xx etc) ----
  // Sources: gphoto2 2.5.33+ "Nikon: support 32bit properties"
  static const int nikonZExposureIndex = 0xD211;
  static const int nikonZShutterSpeed = 0xD213;
  static const int nikonZAperture = 0xD21A;
  static const int nikonZWhiteBalance = 0xD21B;
  static const int nikonZExposureCompensation = 0xD216;
  static const int nikonZExposureProgramMode = 0xD212;

  // Legacy aliases (kept for backward compat)
  static const int nikonExposureIndex = 0xD011; // older cameras
  static const int nikonShutterSpeed = 0xD013;
  static const int nikonAperture = 0xD01A;
  static const int nikonWhiteBalance = 0xD01B;
  static const int nikonExposureCompensation = 0xD016;
  static const int nikonExposureProgram = 0xD012;
}

/// PTP event codes (standard + Nikon vendor extensions).
///
/// Source: D5300 PTP/IP device info enumeration
abstract final class PtpEvent {
  // Standard PTP events (0x40xx)
  static const int cancelTransaction = 0x4001;
  static const int objectAdded = 0x4002;
  static const int objectRemoved = 0x4003;
  static const int storeAdded = 0x4004;
  static const int storeRemoved = 0x4005;
  static const int devicePropChanged = 0x4006;
  static const int objectInfoChanged = 0x4007;
  static const int deviceInfoChanged = 0x4008;
  static const int requestObjectTransfer = 0x4009;
  static const int storeFull = 0x400A;
  static const int storageInfoChanged = 0x400C;
  static const int captureComplete = 0x400D;

  // Nikon vendor events (0xC1xx)
  static const int nikonObjectAddedInSdram = 0xC101;
  static const int nikonCaptureCompleteRecInSdram = 0xC102;
  static const int nikonRecordingInterrupted = 0xC103;
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
