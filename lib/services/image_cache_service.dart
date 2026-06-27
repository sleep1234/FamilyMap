import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// 图片本地缓存服务
/// 
/// 将网络图片下载到本地文件，下次直接读取本地文件
/// 避免每次启动都重新下载头像
class ImageCacheService {
  static ImageCacheService? _instance;
  static ImageCacheService get instance => _instance ??= ImageCacheService._();
  ImageCacheService._();

  String? _cacheDir;
  final Map<String, ImageProvider> _memoryCache = {};
  static const int _maxMemoryCacheSize = 200;
  final List<String> _memoryCacheOrder = [];
  HttpClient? _httpClient;

  /// 获取缓存目录
  Future<String> get cacheDir async {
    if (_cacheDir != null) return _cacheDir!;
    final dir = await getApplicationDocumentsDirectory();
    _cacheDir = '${dir.path}/image_cache';
    await Directory(_cacheDir!).create(recursive: true);
    return _cacheDir!;
  }

  /// 获取共享 HttpClient
  HttpClient get httpClient {
    _httpClient ??= HttpClient();
    return _httpClient!;
  }

  /// URL 转本地文件名（MD5 哈希）
  String _urlToFileName(String url) {
    final bytes = utf8.encode(url);
    final digest = md5.convert(bytes);
    // 保留扩展名
    final ext = url.contains('.') ? '.${url.split('.').last.split('?').first}' : '';
    return '${digest.toString()}$ext';
  }

  /// 添加到内存缓存（LRU）
  void _addToMemoryCache(String url, ImageProvider provider) {
    if (_memoryCache.containsKey(url)) {
      _memoryCacheOrder.remove(url);
    } else if (_memoryCache.length >= _maxMemoryCacheSize) {
      final oldest = _memoryCacheOrder.removeAt(0);
      _memoryCache.remove(oldest);
    }
    _memoryCache[url] = provider;
    _memoryCacheOrder.add(url);
  }

  /// 获取图片的 ImageProvider（先内存 → 再本地文件 → 最后网络）
  Future<ImageProvider> getImageProvider(String url) async {
    // 1. 内存缓存
    if (_memoryCache.containsKey(url)) {
      return _memoryCache[url]!;
    }

    // 2. 本地文件缓存
    final dir = await cacheDir;
    final fileName = _urlToFileName(url);
    final file = File('$dir/$fileName');

    if (await file.exists()) {
      final provider = FileImage(file);
      _addToMemoryCache(url, provider);
      return provider;
    }

    // 3. 无缓存，返回网络图片（同时异步下载缓存）
    _downloadAndCache(url);
    final provider = NetworkImage(url);
    _addToMemoryCache(url, provider);
    return provider;
  }

  /// 同步获取 ImageProvider（用于 DecorationImage 等同步上下文）
  /// 如果内存有缓存直接返回，否则返回 NetworkImage 并后台缓存
  ImageProvider getCachedProvider(String url) {
    if (_memoryCache.containsKey(url)) {
      return _memoryCache[url]!;
    }
    // 异步检查本地文件
    _checkFileCache(url);
    final provider = NetworkImage(url);
    _addToMemoryCache(url, provider);
    return provider;
  }

  /// 后台检查本地文件缓存
  Future<void> _checkFileCache(String url) async {
    try {
      final dir = await cacheDir;
      final fileName = _urlToFileName(url);
      final file = File('$dir/$fileName');
      if (await file.exists()) {
        final provider = FileImage(file);
        _addToMemoryCache(url, provider);
      } else {
        _downloadAndCache(url);
      }
    } catch (_) {}
  }

  /// 预缓存一批图片（启动时批量下载头像）
  Future<void> precacheAll(List<String> urls) async {
    for (final url in urls) {
      if (!_memoryCache.containsKey(url)) {
        _checkFileCache(url);
      }
    }
  }

  /// 异步下载并缓存图片
  Future<void> _downloadAndCache(String url) async {
    try {
      final request = await httpClient.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode == 200) {
        final dir = await cacheDir;
        final fileName = _urlToFileName(url);
        final file = File('$dir/$fileName');
        await response.pipe(file.openWrite());
        debugPrint('[ImageCache] 缓存完成: $fileName');
      }
    } catch (e) {
      debugPrint('[ImageCache] 缓存失败: $e');
    }
  }

  /// 清除过期缓存（7天前的文件）
  Future<void> cleanExpired() async {
    try {
      final dir = await cacheDir;
      final files = await Directory(dir).list().toList();
      final now = DateTime.now();
      for (final f in files) {
        if (f is File) {
          final stat = await f.stat();
          if (now.difference(stat.modified).inDays > 7) {
            await f.delete();
          }
        }
      }
    } catch (_) {}
  }

  /// 初始化（启动时调用，清理过期缓存）
  Future<void> init() async {
    await cleanExpired();
  }

  /// 释放资源
  void dispose() {
    _httpClient?.close();
    _httpClient = null;
  }
}

/// 带本地缓存的头像图片 Widget
class CachedAvatarImage extends StatelessWidget {
  final String url;
  final double size;
  final double borderRadius;
  final Color bgColor;
  final BoxFit fit;

  const CachedAvatarImage({
    super.key,
    required this.url,
    required this.size,
    required this.borderRadius,
    this.bgColor = Colors.grey,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ImageProvider>(
      future: ImageCacheService.instance.getImageProvider(url),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              color: bgColor,
              image: DecorationImage(
                image: snapshot.data!,
                fit: fit,
                filterQuality: FilterQuality.medium,
                onError: (_, __) {},
              ),
            ),
          );
        }
        // 加载中：纯色占位
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(borderRadius),
            color: bgColor,
          ),
        );
      },
    );
  }
}
