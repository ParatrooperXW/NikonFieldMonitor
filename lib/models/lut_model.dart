// LUT model — represents a 3D LUT loaded from a .cube file.
//
// A .cube file (Adobe/Resolve format) lists:
//   LUT_3D_SIZE N           (N^3 entries, default 17)
//   LUT_3D_INPUT_RANGE lo hi (optional, default 0..1)
//   ... N^3 lines of "r g b" triples in [0..1]
//
// The 3D LUT is packed into a 2D texture (N * N) wide x N tall for upload
// to the GPU. The fragment shader samples it via the standard 2D-packed
// 3D LUT technique with trilinear interpolation.
//
// References:
//   - Adobe Cube LUT spec
//   - "How to use a 3D LUT as a 2D texture" (Matt Diamond / Oscar method)
library;

import 'dart:typed_data';

/// A parsed 3D LUT.
class LutModel {
  LutModel({
    required this.id,
    required this.name,
    required this.size,
    required this.rgb,
    this.inputMin = 0.0,
    this.inputMax = 1.0,
    this.isBuiltin = false,
  });

  /// Stable id (uuid or builtin key).
  final String id;

  /// Human-readable name shown in the picker.
  final String name;

  /// LUT size N (number of samples per axis). Supported: 17, 25, 33, 64.
  final int size;

  /// Flattened RGBA bytes for the 2D-packed texture: width = size*size, height = size.
  /// Each texel is 4 bytes (r,g,b,a=255). Total length = size^3 * 4.
  final Uint8List rgb;

  /// Input range from the .cube file (default 0..1).
  final double inputMin;
  final double inputMax;

  /// True for the built-in N-Log -> Rec.709 LUT.
  final bool isBuiltin;

  int get texWidth => size * size;
  int get texHeight => size;

  @override
  String toString() => 'LutModel($name, size=$size, builtin=$isBuiltin)';
}

/// Parse a .cube file text into a [LutModel] with a packed RGBA texture.
///
/// Throws [FormatException] on malformed input.
LutModel parseCubeLut(
  String text, {
  required String id,
  required String name,
  bool isBuiltin = false,
}) {
  var size = 0;
  var inputMin = 0.0;
  var inputMax = 1.0;
  final triples = <(double, double, double)>[];

  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final upper = line.toUpperCase();
    if (upper.startsWith('LUT_3D_SIZE')) {
      size = int.parse(line.split(RegExp(r'\s+'))[1]);
      continue;
    }
    if (upper.startsWith('LUT_3D_INPUT_RANGE')) {
      final parts = line.split(RegExp(r'\s+'));
      inputMin = double.parse(parts[1]);
      inputMax = double.parse(parts[2]);
      continue;
    }
    if (upper.startsWith('LUT_1D_SIZE') ||
        upper.startsWith('TITLE') ||
        upper.startsWith('DOMAIN_MIN') ||
        upper.startsWith('DOMAIN_MAX')) {
      continue;
    }
    // data line: "r g b"
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 3) continue;
    final r = double.parse(parts[0]);
    final g = double.parse(parts[1]);
    final b = double.parse(parts[2]);
    triples.add((r, g, b));
  }

  if (size == 0) {
    throw const FormatException('Missing LUT_3D_SIZE in .cube file');
  }
  final expected = size * size * size;
  if (triples.length != expected) {
    throw FormatException(
      'LUT size mismatch: expected $expected entries, got ${triples.length}',
    );
  }

  // Pack into 2D texture: for each z in [0,size), for each y in [0,size),
  // row of size x-values. The 2D layout is:
  //   texX = (z % size) * size + x
  //   texY = y
  // This is the standard "2D-packed 3D LUT" mapping used by the shader.
  final rgba = Uint8List(expected * 4);
  final scale = inputMax > inputMin ? 1.0 / (inputMax - inputMin) : 1.0;
  for (var z = 0; z < size; z++) {
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        // .cube index order: r varies fastest, then g, then b
        // index = (b * size + g) * size + r   (per Adobe spec)
        final idx = (z * size + y) * size + x;
        final (r, g, b) = triples[idx];
        final tx = (z % size) * size + x;
        final ty = y;
        final off = (ty * size * size + tx) * 4;
        rgba[off + 0] = _clampByte(((r - inputMin) * scale) * 255.0);
        rgba[off + 1] = _clampByte(((g - inputMin) * scale) * 255.0);
        rgba[off + 2] = _clampByte(((b - inputMin) * scale) * 255.0);
        rgba[off + 3] = 255;
      }
    }
  }

  return LutModel(
    id: id,
    name: name,
    size: size,
    rgb: rgba,
    inputMin: inputMin,
    inputMax: inputMax,
    isBuiltin: isBuiltin,
  );
}

int _clampByte(double v) {
  final i = (v.round());
  if (i < 0) return 0;
  if (i > 255) return 255;
  return i;
}
