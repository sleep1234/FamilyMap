import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class CachedTileProvider extends TileProvider {
  Directory? _cacheDir;
  final http.Client _client = http.Client();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    final dir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${dir.path}/map_tiles');
    _initialized = true;
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return CachedTileImage(
      url: getTileUrl(coordinates, options),
      z: coordinates.z,
      x: coordinates.x,
      y: coordinates.y,
      provider: this,
    );
  }

  Future<Uint8List?> loadTile(int z, int x, int y) async {
    if (!_initialized) await init();
    final localPath = '${_cacheDir!.path}/$z/$x/$y.png';
    final localFile = File(localPath);

    if (await localFile.exists()) {
      return localFile.readAsBytes();
    }

    final data = await _fetchFromOrigin(z, x, y);
    if (data != null) {
      await _saveToLocal(localPath, data);
    }
    return data;
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

@immutable
class CachedTileImage extends ImageProvider<CachedTileImage> {
  final String url;
  final int z, x, y;
  final CachedTileProvider provider;

  const CachedTileImage({
    required this.url,
    required this.z,
    required this.x,
    required this.y,
    required this.provider,
  });

  @override
  Future<CachedTileImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(CachedTileImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1.0,
    );
  }

  Future<Codec> _load(CachedTileImage key, ImageDecoderCallback decode) async {
    final data = await provider.loadTile(key.z, key.x, key.y);
    if (data != null) {
      return ImmutableBuffer.fromUint8List(data).then(decode);
    }
    return ImmutableBuffer.fromUint8List(TileProvider.transparentImage).then(decode);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CachedTileImage && z == other.z && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(z, x, y);
}
