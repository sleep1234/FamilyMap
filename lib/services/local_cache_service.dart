import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地缓存服务
/// 
/// 设计原则：先展示缓存 → 后台静默刷新
/// 解决启动白屏/空白等待问题
class LocalCacheService {
  static LocalCacheService? _instance;
  static LocalCacheService get instance => _instance ??= LocalCacheService._();
  LocalCacheService._();

  SharedPreferences? _prefs;

  Future<SharedPreferences> get prefs async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // ==================== 深色模式 ====================

  /// 保存深色模式到本地
  Future<void> saveDarkMode(bool isDark) async {
    final p = await prefs;
    await p.setBool('cache_dark_mode', isDark);
  }

  /// 读取本地深色模式（null 表示从未设置过）
  Future<bool?> getDarkMode() async {
    final p = await prefs;
    return p.getBool('cache_dark_mode');
  }

  // ==================== 成员列表 ====================

  /// 保存成员列表到本地（JSON 数组）
  Future<void> saveMembers(List<Map<String, dynamic>> members) async {
    final p = await prefs;
    await p.setString('cache_members', jsonEncode(members));
    await p.setInt('cache_members_time', DateTime.now().millisecondsSinceEpoch);
  }

  /// 读取本地缓存的成员列表
  Future<List<Map<String, dynamic>>?> getMembers() async {
    final p = await prefs;
    final str = p.getString('cache_members');
    if (str == null) return null;
    try {
      final list = jsonDecode(str) as List;
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      return null;
    }
  }

  /// 获取成员列表缓存时间
  Future<DateTime?> getMembersCacheTime() async {
    final p = await prefs;
    final ms = p.getInt('cache_members_time');
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  // ==================== 成员最新位置 ====================

  /// 保存单个成员的最新位置（实时更新，key 按用户ID区分）
  Future<void> saveMemberPosition(String userId, Map<String, dynamic> data) async {
    final p = await prefs;
    // 合并到统一的 positions map
    final allStr = p.getString('cache_member_positions') ?? '{}';
    final all = jsonDecode(allStr) as Map<String, dynamic>;
    all[userId] = data;
    await p.setString('cache_member_positions', jsonEncode(all));
  }

  /// 批量保存成员位置
  Future<void> saveMemberPositions(Map<String, dynamic> positions) async {
    final p = await prefs;
    await p.setString('cache_member_positions', jsonEncode(positions));
  }

  /// 读取所有缓存的成员位置
  Future<Map<String, dynamic>> getMemberPositions() async {
    final p = await prefs;
    final str = p.getString('cache_member_positions');
    if (str == null) return {};
    try {
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (e) {
      return {};
    }
  }

  // ==================== 圈子列表 ====================

  /// 保存圈子列表
  Future<void> saveCircles(List<Map<String, dynamic>> circles) async {
    final p = await prefs;
    await p.setString('cache_circles', jsonEncode(circles));
  }

  /// 读取本地圈子列表
  Future<List<Map<String, dynamic>>?> getCircles() async {
    final p = await prefs;
    final str = p.getString('cache_circles');
    if (str == null) return null;
    try {
      final list = jsonDecode(str) as List;
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      return null;
    }
  }

  // ==================== 围栏 ====================

  /// 保存围栏列表（按圈子ID）
  Future<void> saveGeofences(String circleId, List<Map<String, dynamic>> fences) async {
    final p = await prefs;
    await p.setString('cache_geofences_$circleId', jsonEncode(fences));
  }

  /// 读取本地围栏缓存
  Future<List<Map<String, dynamic>>?> getGeofences(String circleId) async {
    final p = await prefs;
    final str = p.getString('cache_geofences_$circleId');
    if (str == null) return null;
    try {
      final list = jsonDecode(str) as List;
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      return null;
    }
  }

  // ==================== 用户设置 ====================

  /// 保存用户设置
  Future<void> saveUserSettings(String userId, Map<String, dynamic> settings) async {
    final p = await prefs;
    await p.setString('cache_user_settings_$userId', jsonEncode(settings));
  }

  /// 读取本地用户设置缓存
  Future<Map<String, dynamic>?> getUserSettings(String userId) async {
    final p = await prefs;
    final str = p.getString('cache_user_settings_$userId');
    if (str == null) return null;
    try {
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  // ==================== 逆地理编码 ====================

  static const int _maxGeocodeCacheSize = 5000;

  /// 保存逆地理编码结果（key: "lat,lng"）
  Future<void> saveGeocodeResult(double lat, double lng, String address) async {
    final p = await prefs;
    final key = 'cache_geocode_${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    // 检查是否达到上限，超过则清除一半旧缓存
    final geocodeKeys = p.getKeys().where((k) => k.startsWith('cache_geocode_')).toList();
    if (geocodeKeys.length >= _maxGeocodeCacheSize && !p.getKeys().contains(key)) {
      // 删除最旧的一半
      final toRemove = geocodeKeys.sublist(0, geocodeKeys.length ~/ 2);
      for (final k in toRemove) {
        await p.remove(k);
      }
    }
    await p.setString(key, address);
  }

  /// 读取逆地理编码缓存
  Future<String?> getGeocodeResult(double lat, double lng) async {
    final p = await prefs;
    final key = 'cache_geocode_${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    return p.getString(key);
  }

  // ==================== 工具方法 ====================

  /// 清除所有缓存（退出登录时调用）
  Future<void> clearAll() async {
    final p = await prefs;
    // 先清除需要保留的 key
    final userToken = p.getString('familymap_user');
    final darkMode = p.getBool('cache_dark_mode');
    // 一次性清空所有缓存
    await p.clear();
    // 恢复需要保留的 key
    if (userToken != null) await p.setString('familymap_user', userToken);
    if (darkMode != null) await p.setBool('cache_dark_mode', darkMode);
  }
}
