import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';

/// API 服务 - 与后端 REST API 通信
class ApiService {
  final String baseUrl;

  ApiService({this.baseUrl = 'http://www.zhp0104.fun:8090'});

  // ==================== 用户 ====================

  /// 注册新用户（用户名+密码+昵称）
  Future<AppUser> registerUser(String username, String password, String name) async {
    final res = await _post('/api/register', {'username': username, 'password': password, 'name': name});
    return AppUser.fromJson(res);
  }

  /// 登录（用户名+密码）
  Future<AppUser> loginUser(String username, String password) async {
    final res = await _post('/api/login', {'username': username, 'password': password});
    return AppUser.fromJson(res);
  }

  /// 旧版注册（兼容：仅昵称）
  @Deprecated('Use registerUser with username/password instead')
  Future<AppUser> registerUserLegacy(String name) async {
    final res = await _post('/api/users', {'name': name});
    return AppUser.fromJson(res);
  }

  /// 获取用户信息
  Future<AppUser> getUser(String userId) async {
    final res = await _get('/api/users/$userId');
    return AppUser.fromJson(res);
  }

  /// 更新用户信息（名字、头像颜色、心情、睡眠、幽灵模式）
  Future<void> updateUser(String userId, Map<String, dynamic> data) async {
    await _put('/api/users/$userId', data);
  }

  // ==================== 圈子 ====================

  /// 创建圈子
  Future<Circle> createCircle(String name, String userId) async {
    final res = await _post('/api/circles', {'name': name, 'userId': userId});
    return Circle.fromJson(res);
  }

  /// 加入圈子
  Future<Map<String, dynamic>> joinCircle(String inviteCode, String userId) async {
    return await _post('/api/circles/join', {'inviteCode': inviteCode, 'userId': userId});
  }

  /// 获取用户的所有圈子
  Future<List<Circle>> getUserCircles(String userId) async {
    final list = await _getList('/api/users/$userId/circles');
    return list.map((e) => Circle.fromJson(e)).toList();
  }

  /// 获取圈子成员（含最新位置和停留信息）
  Future<List<Map<String, dynamic>>> getCircleMembers(String circleId) async {
    final list = await _getList('/api/circles/$circleId/members');
    debugPrint('[API] getCircleMembers: 返回 ${list.length} 个成员');
    for (final m in list) {
      debugPrint('[API]   成员: ${(m as Map)['name']}, address=${(m)['address']}, lat=${(m)['latitude']}, lng=${(m)['longitude']}');
    }
    return list.cast<Map<String, dynamic>>();
  }

  // ==================== 位置 ====================

  /// 获取用户位置历史
  Future<List<Map<String, dynamic>>> getUserLocations(String userId, {int hours = 24}) async {
    final list = await _getList('/api/users/$userId/locations?hours=$hours');
    return list.cast<Map<String, dynamic>>();
  }

  /// 逆地理解码
  Future<Map<String, dynamic>> reverseGeocode(double lat, double lng) async {
    debugPrint('[API] reverseGeocode 请求: lat=$lat, lng=$lng');
    try {
      final result = await _get('/api/geocode?lat=$lat&lng=$lng');
      debugPrint('[API] reverseGeocode 返回: address=${result['address']}, formatted=${result['formatted']}');
      return result;
    } catch (e) {
      debugPrint('[API] reverseGeocode 失败: $e');
      rethrow;
    }
  }

  // ==================== 围栏 ====================

  /// 获取圈子围栏
  Future<List<Geofence>> getGeofences(String circleId) async {
    final list = await _getList('/api/circles/$circleId/geofences');
    return list.map((e) => Geofence.fromJson(e)).toList();
  }

  /// 创建围栏
  Future<Geofence> createGeofence(String circleId, String name, double lat, double lng, int radius, String createdBy) async {
    final res = await _post('/api/circles/$circleId/geofences', {
      'name': name, 'latitude': lat, 'longitude': lng, 'radius': radius, 'createdBy': createdBy,
    });
    return Geofence.fromJson(res);
  }

  /// 删除围栏
  Future<void> deleteGeofence(int id) async {
    await _delete('/api/geofences/$id');
  }

  // ==================== 停留记录 ====================

  /// 获取用户停留记录
  Future<List<Stay>> getUserStays(String userId, {int days = 7}) async {
    final list = await _getList('/api/users/$userId/stays?days=$days');
    return list.map((e) => Stay.fromJson(e)).toList();
  }

  // ==================== 时间线 ====================

  /// 获取某天的时间线
  Future<List<Stay>> getTimeline(String userId, {String? date}) async {
    final d = date ?? DateTime.now().toIso8601String().split('T')[0];
    final list = await _getList('/api/users/$userId/timeline?date=$d');
    return list.map((e) => Stay.fromJson(e)).toList();
  }

  /// 获取某天的历史轨迹点（按分钟采样）
  Future<List<Map<String, dynamic>>> getTrack(String userId, {String? date}) async {
    final d = date ?? DateTime.now().toIso8601String().split('T')[0];
    final list = await _getList('/api/users/$userId/track?date=$d');
    return list.cast<Map<String, dynamic>>();
  }

  // ==================== SOS ====================

  /// 发送 SOS 警报
  Future<Map<String, dynamic>> sendSos(String userId, double lat, double lng) async {
    return await _post('/api/sos', {'userId': userId, 'latitude': lat, 'longitude': lng});
  }

  /// 解除 SOS
  Future<void> resolveSos(int id) async {
    await _put('/api/sos/$id/resolve', {});
  }

  // ==================== 聊天 ====================

  /// 获取圈子消息
  Future<List<Message>> getMessages(String circleId, {int limit = 50, int? before}) async {
    var url = '/api/circles/$circleId/messages?limit=$limit';
    if (before != null) url += '&before=$before';
    final list = await _getList(url);
    return list.map((e) => Message.fromJson(e)).toList();
  }

  /// 发送消息
  Future<Message> sendMessage(String circleId, String userId, String content, {String type = 'text'}) async {
    final res = await _post('/api/circles/$circleId/messages', {
      'userId': userId, 'type': type, 'content': content,
    });
    return Message.fromJson(res);
  }

  // ==================== 足迹 ====================

  /// 获取用户足迹
  Future<List<Footprint>> getFootprints(String userId) async {
    final list = await _getList('/api/users/$userId/footprints');
    return list.map((e) => Footprint.fromJson(e)).toList();
  }

  /// 创建足迹
  Future<Footprint> createFootprint(String userId, String name, double lat, double lng, {String category = 'other'}) async {
    final res = await _post('/api/users/$userId/footprints', {
      'name': name, 'latitude': lat, 'longitude': lng, 'category': category,
    });
    return Footprint.fromJson(res);
  }

  /// 删除足迹
  Future<void> deleteFootprint(int id) async {
    await _delete('/api/footprints/$id');
  }

  // ==================== 用户设置 ====================

  /// 获取用户设置
  Future<UserSettings> getUserSettings(String userId) async {
    final res = await _get('/api/users/$userId/settings');
    return UserSettings.fromJson(res);
  }

  /// 更新用户设置
  Future<void> updateUserSettings(String userId, Map<String, dynamic> data) async {
    await _put('/api/users/$userId/settings', data);
  }

  // ==================== 世界迷雾 ====================

  /// 获取世界统计数据
  Future<WorldStats> getWorldStats(String userId) async {
    final res = await _get('/api/users/$userId/world');
    return WorldStats.fromJson(res);
  }

  // ==================== 联系人 ====================

  /// 添加联系人
  Future<void> addContact(String userId, String contactId, {String type = 'friend'}) async {
    await _post('/api/contacts', {'userId': userId, 'contactId': contactId, 'type': type});
  }

  /// 删除联系人
  Future<void> deleteContact(String userId, String contactId) async {
    await _delete('/api/contacts/$userId/$contactId');
  }

  /// 获取联系人列表
  Future<List<Contact>> getContacts(String userId) async {
    final list = await _getList('/api/users/$userId/contacts');
    return list.map((e) => Contact.fromJson(e)).toList();
  }

  // ==================== 4.1 ETA ====================

  /// ETA到达预估
  Future<Map<String, dynamic>> getEta(double fromLat, double fromLng, double toLat, double toLng, {double? speed}) async {
    var url = '/api/eta?fromLat=$fromLat&fromLng=$fromLng&toLat=$toLat&toLng=$toLng';
    if (speed != null) url += '&speed=$speed';
    return await _get(url);
  }

  // ==================== 4.2 分享链接 ====================

  /// 生成位置分享链接
  Future<Map<String, dynamic>> createShareLink(String userId, double lat, double lng, {int durationMinutes = 60, bool trackMode = false}) async {
    return await _post('/api/share-link', {
      'userId': userId, 'latitude': lat, 'longitude': lng, 'durationMinutes': durationMinutes, 'trackMode': trackMode,
    });
  }

  // ==================== 4.3 紧急联系人 ====================

  /// 获取紧急联系人
  Future<List<Map<String, dynamic>>> getEmergencyContacts(String userId) async {
    final list = await _getList('/api/users/$userId/emergency-contacts');
    return list.cast<Map<String, dynamic>>();
  }

  /// 添加紧急联系人
  Future<void> addEmergencyContact(String userId, String name, String phone, {String relation = 'family'}) async {
    await _post('/api/users/$userId/emergency-contacts', {'name': name, 'phone': phone, 'relation': relation});
  }

  /// 删除紧急联系人
  Future<void> deleteEmergencyContact(int id) async {
    await _delete('/api/emergency-contacts/$id');
  }

  // ==================== 4.8 GPX导出 ====================

  /// GPX导出URL
  String getGpxExportUrl(String userId, {String? date}) {
    final d = date ?? DateTime.now().toIso8601String().split('T')[0];
    return '$baseUrl/api/users/$userId/export/gpx?date=$d';
  }

  // ==================== 4.5 位置历史热力图 ====================

  /// 获取用户热力图数据
  Future<Map<String, dynamic>> getHeatmap(String userId, {int days = 7}) async {
    return _get('/api/users/$userId/heatmap?days=$days');
  }

  // ==================== 4.9 驾驶行为评分 ====================

  /// 获取驾驶行为评分
  Future<Map<String, dynamic>> getDrivingScore(String userId, {int days = 7}) async {
    return _get('/api/users/$userId/driving-score?days=$days');
  }

  // ==================== 基础 HTTP 方法 ====================

  Future<Map<String, dynamic>> _get(String path) async {
    final res = await http.get(Uri.parse('$baseUrl$path'));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> _getList(String path) async {
    final res = await http.get(Uri.parse('$baseUrl$path'));
    return jsonDecode(res.body) as List;
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final res = await http.post(
      Uri.parse('$baseUrl$path'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _put(String path, Map<String, dynamic> body) async {
    final res = await http.put(
      Uri.parse('$baseUrl$path'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> _delete(String path) async {
    await http.delete(Uri.parse('$baseUrl$path'));
  }
}
