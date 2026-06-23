// ==================== FamilyMap 数据模型 ====================
// 所有数据类集中管理，方便维护

/// 用户
class AppUser {
  final String id;
  final String name;
  final String avatarColor;
  String? avatarUrl;    // 自定义头像URL or 预设头像路径（可变，设置页修改后直接更新）
  final String? mood;       // 心情文字
  bool isSleeping;    // 睡眠状态（设置页需要可变，以便SwitchListTile刷新）
  final String ghostMode;   // off / invisible / blur
  final String? username;   // 登录用户名
  final String? token;      // 会话 token（多设备互踢用）
  final DateTime? createdAt;

  AppUser({
    required this.id,
    required this.name,
    this.avatarColor = '#4F46E5',
    this.avatarUrl,
    this.mood,
    this.isSleeping = false,
    this.ghostMode = 'off',
    this.username,
    this.token,
    this.createdAt,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'],
        name: json['name'],
        avatarColor: json['avatar_color'] ?? '#4F46E5',
        avatarUrl: json['avatar_url'],
        mood: json['mood'],
        isSleeping: (json['is_sleeping'] ?? 0) == 1,
        ghostMode: json['ghost_mode'] ?? 'off',
        username: json['username'],
        token: json['token'],
        createdAt: json['created_at'] != null
            ? Stay.parseUtcToLocal(json['created_at'])
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'avatar_color': avatarColor,
        'avatar_url': avatarUrl,
        'mood': mood,
        'is_sleeping': isSleeping ? 1 : 0,
        'ghost_mode': ghostMode,
        'username': username,
        'token': token,
      };
}

/// 成员位置（实时）
class MemberLocation {
  final String userId;
  final double latitude;
  final double longitude;
  final double? accuracy;
  final int? batteryLevel;
  final bool? isCharging;
  final double? speed;
  final String? address;       // 逆地理地址
  final DateTime? recordedAt;
  final String? ghostMode;    // off / blur / invisible
  final String? stayAddress;  // 当前停留地址
  final int? stayMinutes;     // 当前停留时长（分钟）
  final DateTime? stayStartedAt; // 停留开始时间，用于前端实时计算
  final String? trailSkin;    // 拖尾皮肤

  MemberLocation({
    required this.userId,
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.batteryLevel,
    this.isCharging,
    this.speed,
    this.address,
    this.recordedAt,
    this.ghostMode,
    this.stayAddress,
    this.stayMinutes,
    this.stayStartedAt,
    this.trailSkin,
  });

  factory MemberLocation.fromJson(Map<String, dynamic> json) => MemberLocation(
        userId: json['user_id'] ?? json['userId'],
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        accuracy: json['accuracy'] != null
            ? (json['accuracy'] as num).toDouble()
            : null,
        batteryLevel: json['battery_level'] != null
            ? (json['battery_level'] as num).toInt()
            : json['batteryLevel'] != null
                ? (json['batteryLevel'] as num).toInt()
                : null,
        isCharging: json['is_charging'] == 1 ||
            json['isCharging'] == true,
        speed: json['speed'] != null
            ? (json['speed'] as num).toDouble()
            : null,
        address: json['address'],
        recordedAt: json['recorded_at'] != null
            ? Stay.parseUtcToLocal(json['recorded_at'])
            : json['timestamp'] != null
                ? DateTime.fromMillisecondsSinceEpoch(json['timestamp'])
                : null,
        ghostMode: json['ghostMode'] ?? json['ghost_mode'],
        stayAddress: json['stay_address'],
        stayMinutes: json['stay_minutes'] != null
            ? (json['stay_minutes'] as num).toInt()
            : null,
        stayStartedAt: json['stay_started_at'] != null
            ? Stay.parseUtcToLocal(json['stay_started_at'])
            : null,
        trailSkin: json['trailSkin'] ?? json['trail_skin'],
      );
}

/// 圈子
class Circle {
  final String id;
  final String name;
  final String inviteCode;
  final int memberCount;

  Circle({
    required this.id,
    required this.name,
    required this.inviteCode,
    this.memberCount = 1,
  });

  factory Circle.fromJson(Map<String, dynamic> json) => Circle(
        id: json['id'],
        name: json['name'],
        inviteCode: json['invite_code'] ?? '',
        memberCount: json['member_count'] ?? 1,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'invite_code': inviteCode,
        'member_count': memberCount,
      };
}

/// 地理围栏
class Geofence {
  final int? id;
  final String circleId;
  final String name;
  final double latitude;
  final double longitude;
  final int radius;

  Geofence({
    this.id,
    required this.circleId,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.radius = 200,
  });

  factory Geofence.fromJson(Map<String, dynamic> json) => Geofence(
        id: json['id'],
        circleId: json['circle_id'] ?? '',
        name: json['name'],
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        radius: (json['radius'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'circle_id': circleId,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'radius': radius,
      };
}

/// 停留记录
class Stay {
  final int? id;
  final String userId;
  final double latitude;
  final double longitude;
  final String? address;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final int? durationMinutes;

  Stay({
    this.id,
    required this.userId,
    required this.latitude,
    required this.longitude,
    this.address,
    this.startedAt,
    this.endedAt,
    this.durationMinutes,
  });

  factory Stay.fromJson(Map<String, dynamic> json) => Stay(
        id: json['id'],
        userId: json['user_id'] ?? '',
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        address: json['address'],
        // 服务器存的是 UTC 时间但无 Z 后缀，补 Z 后按 UTC 解析再转本地时间
        startedAt: json['started_at'] != null
            ? Stay.parseUtcToLocal(json['started_at'])
            : null,
        endedAt: json['ended_at'] != null
            ? Stay.parseUtcToLocal(json['ended_at'])
            : null,
        durationMinutes: json['duration_minutes'] != null
            ? (json['duration_minutes'] as num).toInt()
            : null,
      );

  /// 解析服务器返回的 UTC 时间字符串（无 Z 后缀）为本地 DateTime
  static DateTime? parseUtcToLocal(String? s) {
    if (s == null) return null;
    // 如果已有 Z 或 +08:00 后缀，直接解析
    if (s.endsWith('Z') || s.contains('+')) return DateTime.tryParse(s)?.toLocal();
    // 否则当作 UTC 解析后转本地
    return DateTime.tryParse('${s}Z')?.toLocal();
  }

  /// 格式化停留时长：xx天xx时xx分（与地图标记格式一致）
  String get durationText {
    final mins = durationMinutes ?? 0;
    if (mins <= 0) return '0分';
    final d = mins ~/ (24 * 60);
    final h = (mins % (24 * 60)) ~/ 60;
    final m = mins % 60;
    final parts = <String>[];
    if (d > 0) parts.add('${d}天');
    if (h > 0) parts.add('${h}时');
    if (m > 0) parts.add('${m}分');
    if (parts.isEmpty) parts.add('${mins}分');
    return parts.join('');
  }
}

/// 聊天消息
class Message {
  final int? id;
  final String circleId;
  final String userId;
  final String type;        // text / emoji / image
  final String content;
  final String? userName;
  final String? avatarColor;
  final String? avatarUrl;
  final DateTime? createdAt;

  Message({
    this.id,
    required this.circleId,
    required this.userId,
    this.type = 'text',
    required this.content,
    this.userName,
    this.avatarColor,
    this.avatarUrl,
    this.createdAt,
  });

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'],
        circleId: json['circle_id'] ?? '',
        userId: json['user_id'] ?? '',
        type: json['type'] ?? 'text',
        content: json['content'] ?? '',
        userName: json['name'],
        avatarColor: json['avatar_color'],
        avatarUrl: json['avatar_url'],
        createdAt: json['created_at'] != null
            ? Stay.parseUtcToLocal(json['created_at'])
            : null,
      );
}

/// SOS 警报
class SosAlert {
  final int? id;
  final String userId;
  final double latitude;
  final double longitude;
  final String? address;
  final String status;      // active / resolved
  final DateTime? createdAt;

  SosAlert({
    this.id,
    required this.userId,
    required this.latitude,
    required this.longitude,
    this.address,
    this.status = 'active',
    this.createdAt,
  });

  factory SosAlert.fromJson(Map<String, dynamic> json) => SosAlert(
        id: json['id'],
        userId: json['user_id'] ?? '',
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        address: json['address'],
        status: json['status'] ?? 'active',
        createdAt: json['created_at'] != null
            ? Stay.parseUtcToLocal(json['created_at'])
            : json['timestamp'] != null
                ? DateTime.fromMillisecondsSinceEpoch(json['timestamp'])
                : null,
      );
}

/// 足迹
class Footprint {
  final int? id;
  final String userId;
  final String name;
  final double latitude;
  final double longitude;
  final String category;    // home / work / school / food / fun / other
  final String note;        // 备注
  final DateTime? createdAt;

  Footprint({
    this.id,
    required this.userId,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.category = 'other',
    this.note = '',
    this.createdAt,
  });

  factory Footprint.fromJson(Map<String, dynamic> json) => Footprint(
        id: json['id'],
        userId: json['user_id'] ?? '',
        name: json['name'] ?? '',
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        category: json['category'] ?? 'other',
        note: json['note'] ?? '',
        createdAt: json['created_at'] != null
            ? Stay.parseUtcToLocal(json['created_at'])
            : null,
      );
}

/// 用户设置
class UserSettings {
  final String userId;
  final bool blurLocation;
  final bool sharePaused;
  final String trailSkin;       // default / fire / ice / rainbow / galaxy
  final String nicknameColor;   // 空字符串=默认颜色, 否则为hex色值
  final bool darkMode;
  final String lang;            // zh / en
  final String barkKey;         // Bark 推送密钥

  UserSettings({
    required this.userId,
    this.blurLocation = false,
    this.sharePaused = false,
    this.trailSkin = 'default',
    this.nicknameColor = '',
    this.darkMode = false,
    this.lang = 'zh',
    this.barkKey = '',
  });

  factory UserSettings.fromJson(Map<String, dynamic> json) => UserSettings(
        userId: json['user_id'] ?? '',
        blurLocation: (json['blur_location'] ?? 0) == 1,
        sharePaused: (json['share_paused'] ?? 0) == 1,
        trailSkin: json['trail_skin'] ?? 'default',
        nicknameColor: json['nickname_color'] ?? '',
        darkMode: (json['dark_mode'] ?? 0) == 1,
        lang: json['lang'] ?? 'zh',
        barkKey: json['bark_key'] ?? '',
      );

  Map<String, dynamic> toJson() => {
        'blur_location': blurLocation ? 1 : 0,
        'share_paused': sharePaused ? 1 : 0,
        'trail_skin': trailSkin,
        'nickname_color': nicknameColor,
        'dark_mode': darkMode ? 1 : 0,
        'lang': lang,
        'bark_key': barkKey,
      };
}

/// 联系人
class Contact {
  final int? id;
  final String userId;
  final String contactId;
  final String type;      // friend / family
  final String? name;
  final String? avatarColor;
  final String? avatarUrl;

  Contact({
    this.id,
    required this.userId,
    required this.contactId,
    this.type = 'friend',
    this.name,
    this.avatarColor,
    this.avatarUrl,
  });

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        id: json['id'],
        userId: json['user_id'] ?? '',
        contactId: json['contact_id'] ?? '',
        type: json['type'] ?? 'friend',
        name: json['name'],
        avatarColor: json['avatar_color'],
        avatarUrl: json['avatar_url'],
      );
}

/// 世界迷雾网格点
class FogGrid {
  final double lat;
  final double lng;
  FogGrid({required this.lat, required this.lng});
  factory FogGrid.fromJson(Map<String, dynamic> json) => FogGrid(
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
      );
}

/// 世界迷雾统计
class WorldStats {
  final int gridCount;
  final List<String> cities;
  final int cityCount;
  final List<FogGrid> grids; // 网格坐标，供迷雾遮罩绘制

  WorldStats({
    this.gridCount = 0,
    this.cities = const [],
    this.cityCount = 0,
    this.grids = const [],
  });

  factory WorldStats.fromJson(Map<String, dynamic> json) => WorldStats(
        gridCount: json['gridCount'] ?? 0,
        cities: List<String>.from(json['cities'] ?? []),
        cityCount: json['cityCount'] ?? 0,
        grids: (json['grids'] as List?)?.map((g) => FogGrid.fromJson(g as Map<String, dynamic>)).toList() ?? [],
      );
}
