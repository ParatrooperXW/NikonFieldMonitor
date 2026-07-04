// LUT service — loads, parses, caches and uploads .cube LUTs.
//
// Built-in LUT (N-Log -> Rec.709) is bundled in assets/luts/. User LUTs are
// imported via file_picker and cached in the app's documents directory so
// they survive app restarts. Parsed RGBA is uploaded to the GPU via
// [RenderBridge.uploadLut].
library;

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/lut_model.dart';
import '../native_bridge/native_render_bridge.dart';

class LutService {
  LutService(this._bridge);

  final RenderBridge _bridge;
  final _uuid = const Uuid();

  final Map<String, LutModel> _luts = {};
  Map<String, LutModel> get luts => Map.unmodifiable(_luts);

  /// Load the built-in N-Log -> Rec.709 LUT and any user-imported LUTs.
  Future<void> init() async {
    await loadBuiltinLut('assets/luts/nlog_to_rec709.cube',
        id: 'builtin_nlog_rec709', name: 'N-Log → Rec.709');
    await _loadUserLuts();
  }

  Future<LutModel?> loadBuiltinLut(String assetPath,
      {required String id, required String name}) async {
    try {
      final text = await rootBundle.loadString(assetPath);
      final lut = parseCubeLut(text, id: id, name: name, isBuiltin: true);
      _luts[id] = lut;
      await _bridge.uploadLut(id, lut.rgb, lut.size);
      return lut;
    } on Exception {
      // asset not found in this build — skip silently
      return null;
    }
  }

  /// Import a .cube file from disk, parse it, cache it and upload to GPU.
  Future<LutModel> importFromFile(File file, {String? name}) async {
    final text = await file.readAsString();
    final id = _uuid.v4();
    final lut = parseCubeLut(text, id: id, name: name ?? file.uri.pathSegments.last);
    _luts[id] = lut;
    await _bridge.uploadLut(id, lut.rgb, lut.size);
    await _cacheUserLut(file, id);
    return lut;
  }

  Future<void> removeLut(String id) async {
    final lut = _luts.remove(id);
    if (lut == null || lut.isBuiltin) return;
    await _bridge.removeLut(id);
    final dir = await _userLutDir();
    final f = File('${dir.path}/$id.cube');
    if (await f.exists()) await f.delete();
  }

  LutModel? byId(String? id) => id == null ? null : _luts[id];

  Future<Directory> _userLutDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/user_luts');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _cacheUserLut(File source, String id) async {
    final dir = await _userLutDir();
    await source.copy('${dir.path}/$id.cube');
  }

  Future<void> _loadUserLuts() async {
    final dir = await _userLutDir();
    if (!await dir.exists()) return;
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.cube')) continue;
      try {
        final text = await f.readAsString();
        final id = f.uri.pathSegments.last.replaceAll('.cube', '');
        final lut = parseCubeLut(text, id: id, name: 'User LUT $id');
        _luts[id] = lut;
        await _bridge.uploadLut(id, lut.rgb, lut.size);
      } on FormatException {
        // skip malformed file
      }
    }
  }
}
