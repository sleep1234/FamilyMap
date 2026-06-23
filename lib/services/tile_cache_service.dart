import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../config.dart';

class CachedTileProvider extends TileProvider {
  Directory? _cacheDir;
  final http.Client _client = http.Client();
  int _cacheHits = 0;
  int _cacheMisses = 0;
  bool _initialized = false;

  int get cacheHits => _cacheHits;
  int get cacheMisses => _cacheMisses;

  Future<void> init() async {
    if (_initialized) return;
    final dir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${dir.path}/map_tiles');
    _initialized = true;
  }

  @override
  ImageProvider<Object> getImage(TileCoordinates coordinates, TileLayerOptions options) {
    final z = coordinates.z;
    final x = coordinates.x;
    final y = coordinates.y;
    return CachedTileImage(
      z: z, x: x, y: y,
      provider: this,
    );
  }

  Future<Uint8List?> loadTile(int z, int x, int y) async {
    if (!_initialized) await init();
    final localPath = '${_cacheDir!.path}/$z/$x/$y.png';
    final localFile = File(localPath);

    if (await localFile.exists()) {
      _cacheHits++;
      return localFile.readAsBytes();
    }

    _cacheMisses++;

    Uint8List? data = await _fetchFromServerCache(z, x, y);
    if (data != null) {
      await _saveToLocal(localPath, data);
      return data;
    }

    data = await _fetchFromOrigin(z, x, y);
    if (data != null) {
      await _saveToLocal(localPath, data);
    }
    return data;
  }

  Future<Uint8List?> _fetchFromServerCache(int z, int x, int y) async {
    try {
      final url = '${AppConfig.httpBaseUrl}/api/tiles/$z/$x/$y';
      final resp = await _client.get(
        Uri.parse(url),
        headers: {'Accept': 'image/png'},
      ).timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200 && resp.bodyBytes.length > 100) {
        return resp.bodyBytes;
      }
    } catch (_) {}
    return null;
  }

  Future<Uint8List?> _fetchFromOrigin(int z, int x, int y) async {
    try {
      final s = ((x + y) % 4 + 1).toString();
      final url = 'https://webrd0$s.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x=$x&y=$y&z=$z';
      final resp = await _client.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0',
          'Referer': 'https://www.amap.com/',
        },
      ).timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200 && resp.bodyBytes.length > 100) {
        return resp.bodyBytes;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveToLocal(String path, Uint8List data) async {
    try {
      await File(path).create(recursive: true);
      await File(path).writeAsBytes(data);
    } catch (_) {}
  }

  Future<void> clearCache() async {
    final dir = _cacheDir;
    if (dir != null && await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<int> getCacheSize() async {
    int size = 0;
    final dir = _cacheDir;
    if (dir != null && await dir.exists()) {
      await for (final f in dir.list(recursive: true)) {
        if (f is File) size += await f.length();
      }
    }
    return size;
  }
}

class CachedTileImage extends ImageProvider<CachedTileImage> {
  final int z, x, y;
  final CachedTileProvider provider;

  CachedTileImage({required this.z, required this.x, required this.y, required this.provider});

  @override
  Future<CachedTileImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(CachedTileImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: () async {
        final data = await provider.loadTile(key.z, key.x, key.y);
        if (data == null) {
          return await decode(
            Uint8List.fromList(_transparentPixel),
          );
        }
        return await decode(data);
      }(),
      scale: 1.0,
    );
  }

  static final _transparentPixel = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x62, 0x00, 0x00, 0x00, 0x02,
    0x00, 0x01, 0xE5, 0x27, 0xDE, 0xFC, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
    0x60, 0x82,
  ]);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CachedTileImage && z == other.z && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(z, x, y);
}
