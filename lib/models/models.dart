// ==================== FamilyMap 数据模型 ====================
// 所有数据类集中管理，方便维护

/// 用户
class AppUser {
  final String id;
  final String name;
  final String avatarColor;
  final String? mood;       // 心情文字
  final bool isSleeping;    // 睡眠状态
  final String ghostMode;   // off / invisible / blur
  final String? username;   // 登录用户名
  final String? token;      // 会话 token（多设备互踢用）
  final DateTime? createdAt;

  AppUser({
    required this.id,
    required this.name,
    this.avatarColor = '#4F46E5',
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
        mood: json['mood'],
        isSleeping: (json['is_sleeping'] ?? 0) == 1,
        ghostMode: json['ghost_mode'] ?? 'off',
        username: json['username'],
        token: json['token'],
        createdAt: json['created_at'] != null
            ? DateTime.tryParse(json['created_at'])
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'avatar_color': avatarColor,
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
            ? DateTime.tryParse(json['recorded_at'])
            : json['timestamp'] != null
                ? DateTime.fromMillisecondsSinceEpoch(json['timestamp'])
                : null,
        ghostMode: json['ghostMode'] ?? json['ghost_mode'],
        stayAddress: json['stay_address'],
        stayMinutes: json['stay_minutes'] != null
            ? (json['stay_minutes'] as num).toInt()
            : null,
        stayStartedAt: json['stay_started_at'] != null
            ? DateTime.tryParse(json['stay_started_at'])
            : null,
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
        startedAt: json['started_at'] != null
            ? DateTime.tryParse(json['started_at'])
            : null,
        endedAt: json['ended_at'] != null
            ? DateTime.tryParse(json['ended_at'])
            : null,
        durationMinutes: json['duration_minutes'] != null
            ? (json['duration_minutes'] as num).toInt()
            : null,
      );

  /// 格式化停留时长
  String get durationText {
    final mins = durationMinutes ?? 0;
    if (mins < 60) return '$mins分钟';
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h < 24) return '${h}小时${m > 0 ? '${m}分' : ''}';
    final d = h ~/ 24;
    final rh = h % 24;
    return '${d}天${rh > 0 ? '${rh}小时' : ''}';
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
  final DateTime? createdAt;

  Message({
    this.id,
    required this.circleId,
    required this.userId,
    this.type = 'text',
    required this.content,
    this.userName,
    this.avatarColor,
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
        createdAt: json['created_at'] != null
            ? DateTime.tryParse(json['created_at'])
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
            ? DateTime.tryParse(json['created_at'])
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
  final DateTime? createdAt;

  Footprint({
    this.id,
    required this.userId,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.category = 'other',
    this.createdAt,
  });

  factory Footprint.fromJson(Map<String, dynamic> json) => Footprint(
        id: json['id'],
        userId: json['user_id'] ?? '',
        name: json['name'] ?? '',
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        category: json['category'] ?? 'other',
        createdAt: json['created_at'] != null
            ? DateTime.tryParse(json['created_at'])
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

  UserSettings({
    required this.userId,
    this.blurLocation = false,
    this.sharePaused = false,
    this.trailSkin = 'default',
    this.nicknameColor = '',
    this.darkMode = false,
    this.lang = 'zh',
  });

  factory UserSettings.fromJson(Map<String, dynamic> json) => UserSettings(
        userId: json['user_id'] ?? '',
        blurLocation: (json['blur_location'] ?? 0) == 1,
        sharePaused: (json['share_paused'] ?? 0) == 1,
        trailSkin: json['trail_skin'] ?? 'default',
        nicknameColor: json['nickname_color'] ?? '',
        darkMode: (json['dark_mode'] ?? 0) == 1,
        lang: json['lang'] ?? 'zh',
      );

  Map<String, dynamic> toJson() => {
        'blur_location': blurLocation ? 1 : 0,
        'share_paused': sharePaused ? 1 : 0,
        'trail_skin': trailSkin,
        'nickname_color': nicknameColor,
        'dark_mode': darkMode ? 1 : 0,
        'lang': lang,
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

  Contact({
    this.id,
    required this.userId,
    required this.contactId,
    this.type = 'friend',
    this.name,
    this.avatarColor,
  });

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        id: json['id'],
        userId: json['user_id'] ?? '',
        contactId: json['contact_id'] ?? '',
        type: json['type'] ?? 'friend',
        name: json['name'],
        avatarColor: json['avatar_color'],
      );
}

/// 世界迷雾统计
class WorldStats {
  final int gridCount;
  final List<String> cities;
  final int cityCount;

  WorldStats({
    this.gridCount = 0,
    this.cities = const [],
    this.cityCount = 0,
  });

  factory WorldStats.fromJson(Map<String, dynamic> json) => WorldStats(
        gridCount: json['gridCount'] ?? 0,
        cities: List<String>.from(json['cities'] ?? []),
        cityCount: json['cityCount'] ?? 0,
      );
}
