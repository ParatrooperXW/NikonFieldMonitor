// LiveView frame parsing.
//
// Nikon GetLiveViewImg (0x9203) returns a blob:
//   [u32 totalLen]
//   [u8  liveViewStatus]  (0 = idle, 1 = running, 2 = waiting)
//   [u8  reserved]
//   [u32 jpegOffset]
//   [u32 jpegLength]
//   [u32 metadataOffset]
//   [u32 metadataLength]
//   ... padding ...
//   [jpeg bytes at jpegOffset..jpegOffset+jpegLength]
//   [metadata bytes at metadataOffset..]
//
// Some models return a raw YUV/YCbCr payload instead of MJPEG; we detect
// JPEG via the 0xFFD8 SOI marker. Metadata contains AF info, histogram, etc.
//
// References:
//   - gphoto2 camlibs/ptp2/library.c nikon_get_liveview_image()
//   - digiCamControl CameraProperty.cs LiveViewImage
//   - remoteyourcam-usb LiveViewFragment
library;

import 'dart:typed_data';

class LiveViewFrame {
  LiveViewFrame({
    required this.jpeg,
    required this.metadata,
    required this.width,
    required this.height,
    required this.timestamp,
  });

  /// JPEG (or empty when payload was raw YUV — TODO_NIKON support YUV path).
  final Uint8List jpeg;

  /// Optional Nikon LiveView metadata block.
  final Uint8List? metadata;

  final int width;
  final int height;
  final DateTime timestamp;

  bool get isJpeg => jpeg.length >= 2 && jpeg[0] == 0xFF && jpeg[1] == 0xD8;
}

/// Parse the GetLiveViewImg response payload into a [LiveViewFrame].
LiveViewFrame parseLiveViewImg(Uint8List blob) {
  if (blob.length < 24) {
    throw FormatException('LiveView blob too short: ${blob.length}B');
  }
  final bd = ByteData.sublistView(blob);
  final totalLen = bd.getUint32(0, Endian.little);
  final liveViewStatus = bd.getUint8(4);
  // reserved byte at 5
  final jpegOffset = bd.getUint32(8, Endian.little);
  final jpegLength = bd.getUint32(12, Endian.little);
  final metaOffset = bd.getUint32(16, Endian.little);
  final metaLength = bd.getUint32(20, Endian.little);

  if (liveViewStatus == 0 || jpegLength == 0) {
    throw LiveViewNotReadyException('LiveView not running (status=$liveViewStatus)');
  }

  final effectiveLen = totalLen == 0 ? blob.length : totalLen;
  if (jpegOffset + jpegLength > effectiveLen) {
    throw FormatException('JPEG range out of bounds: $jpegOffset+$jpegLength > $effectiveLen');
  }

  final jpeg = blob.sublist(jpegOffset, jpegOffset + jpegLength);
  final meta = (metaLength > 0 && metaOffset + metaLength <= effectiveLen)
      ? blob.sublist(metaOffset, metaOffset + metaLength)
      : null;

  // Width/height are not always in the header; decode from JPEG SOF if needed.
  final dims = _jpegDimensions(jpeg);

  return LiveViewFrame(
    jpeg: jpeg,
    metadata: meta,
    width: dims.$1,
    height: dims.$2,
    timestamp: DateTime.now(),
  );
}

class LiveViewNotReadyException implements Exception {
  LiveViewNotReadyException(this.message);
  final String message;
  @override
  String toString() => 'LiveViewNotReadyException: $message';
}

/// Extract JPEG dimensions by scanning for the SOF0 (0xFFC0) marker.
/// Returns (width, height) or (0,0) if not found.
(int, int) _jpegDimensions(Uint8List jpeg) {
  if (jpeg.length < 4) return (0, 0);
  var i = 2; // skip SOI 0xFFD8
  while (i < jpeg.length - 9) {
    if (jpeg[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = jpeg[i + 1];
    if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) {
      // SOF0/SOF1/SOF2: [FF C0][len:2][precision:1][height:2][width:2]
      final height = (jpeg[i + 5] << 8) | jpeg[i + 6];
      final width = (jpeg[i + 7] << 8) | jpeg[i + 8];
      return (width, height);
    }
    // skip this marker segment
    if (marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
    } else {
      final segLen = (jpeg[i + 2] << 8) | jpeg[i + 3];
      i += 2 + segLen;
    }
  }
  return (0, 0);
}
