import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import '../config.dart';

/// 通知点击回调类型
/// type: 'chat' | 'sos' | 'geofence' | 'thinking_of_you' | 'alert'
/// data: 携带的附加数据（如 circleId）
typedef NotificationTapCallback = void Function(String type, Map<String, dynamic> data);

/// 系统通知服务 — 微信风格：largeIcon 头像 + 小应用图标角标
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  /// 通知渠道 ID
  static const String _foregroundChannelId = 'familymap_foreground';
  static const String _alertChannelId = 'familymap_alerts';

  /// 前台通知 ID
  static const int _foregroundNotificationId = 1000;

  bool _initialized = false;

  /// 递增通知 ID（解决 hash 碰撞问题）
  int _nextNotificationId = 1;
  int _getNotificationId() => _nextNotificationId++;

  /// 通知点击回调（由 MapScreen 注册）
  NotificationTapCallback? onTap;

  /// 头像缓存
  final Map<String, Uint8List> _avatarCache = {};

  /// 初始化
  Future<void> init() async {
    if (_initialized) return;
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
    );
    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );
    _initialized = true;
    debugPrint('[通知] 初始化完成');
  }

  /// 请求通知权限
  Future<bool> requestPermission() async {
    if (Platform.isIOS) {
      final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      if (ios == null) return false;
      final result = await ios.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return result ?? false;
    }
    if (!Platform.isAndroid) return true;
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;
    return await android.requestNotificationsPermission() ?? false;
  }

  /// 打开系统通知设置
  Future<void> openNotificationSettings() async {
    debugPrint('[通知] 请在系统设置中手动开启通知权限');
  }

  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('[通知] 点击通知: id=${response.id}, payload=${response.payload}');
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    try {
      final data = Map<String, dynamic>.from(const JsonDecoder().convert(payload));
      final type = data['type'] as String? ?? 'alert';
      debugPrint('[通知] 解析 payload: type=$type, data=$data');
      onTap?.call(type, data);
    } catch (e) {
      debugPrint('[通知] 解析 payload 失败: $e');
    }
  }

  // ==================== 头像下载 + 裁剪 ====================

  Future<Uint8List?> _downloadAvatar(String? avatarUrl) async {
    if (avatarUrl == null || avatarUrl.isEmpty) return null;

    // 生肖图片型预设 (preset:zodiac_xxx) → 拼接服务器URL
    String effectiveUrl;
    if (avatarUrl.startsWith('preset:zodiac_')) {
      effectiveUrl = '${AppConfig.httpBaseUrl}/uploads/presets/${avatarUrl.substring(7)}.jpg';
    } else if (avatarUrl.startsWith('preset:')) {
      // Emoji型预设通知里无图片可下载，返回null
      return null;
    } else {
      effectiveUrl = avatarUrl.startsWith('http') ? avatarUrl : '${AppConfig.httpBaseUrl}$avatarUrl';
    }

    if (_avatarCache.containsKey(effectiveUrl)) return _avatarCache[effectiveUrl];

    try {
      final response = await http.get(Uri.parse(effectiveUrl));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        final bytes = response.bodyBytes;
        _avatarCache[effectiveUrl] = bytes;
        if (_avatarCache.length > 20) _avatarCache.remove(_avatarCache.keys.first);
        return bytes;
      }
    } catch (e) {
      debugPrint('[通知] 下载头像失败: $e');
    }
    return null;
  }

  /// 将头像裁剪为圆形（Android largeIcon 在通知栏中不会自动裁剪，
  /// 需要手动裁剪为圆形才能实现微信效果）
  Future<Uint8List?> _cropCircle(Uint8List bytes) async {
    try {
      final codec = await instantiateImageCodecFromBuffer(
        await ImmutableBuffer.fromUint8List(bytes),
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final size = image.width < image.height ? image.width : image.height;
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder,
          Rect.fromCircle(center: Offset(size / 2, size / 2), radius: size / 2));
      canvas.clipRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH((image.width - size) / 2, (image.height - size) / 2, size * 1.0, size * 1.0),
        Radius.circular(size / 2),
      ));
      canvas.drawImage(image,
          Offset((image.width - size) / 2 * -1, (image.height - size) / 2 * -1),
          Paint());
      final picture = recorder.endRecording();
      final cropped = await picture.toImage(size, size);
      final byteData = await cropped.toByteData(format: ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('[通知] 裁剪头像个失败: $e');
      return bytes;
    }
  }

  // ==================== 前台常驻通知 ====================

  Future<void> showForegroundNotification({
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      _foregroundChannelId,
      '位置共享服务',
      channelDescription: 'FamilyMap 正在后台持续追踪位置',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showWhen: false,
      silent: true,
    );
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: false,
    );
    const details = NotificationDetails(android: androidDetails, iOS: darwinDetails);
    try {
      await _plugin.show(
        id: _foregroundNotificationId,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (e) {
      debugPrint('[通知] 前台通知失败: $e');
    }
  }

  Future<void> cancelForegroundNotification() async {
    await _plugin.cancel(id: _foregroundNotificationId);
  }

  // ==================== 微信风格消息通知（largeIcon 头像） ====================

  /// 构建 微信风格 通知详情
  /// 核心策略：largeIcon = 发送人头像 → Android 自动在头像右下角叠加小应用图标角标
  /// 这与微信的通知风格一致：大头像左侧 + 小应用角标 + 名称/内容右侧
  Future<AndroidNotificationDetails> _buildChatStyleDetails({
    required String userName,
    required String messageText,
    String? avatarUrl,
    Color color = const Color(0xFF6366F1),
    Importance importance = Importance.high,
    Priority priority = Priority.high,
    bool enableVibration = false,
    Int64List? vibrationPattern,
    bool playSound = false,
  }) async {
    // 下载并裁剪头像为圆形
    Uint8List? avatarBytes;
    final rawBytes = await _downloadAvatar(avatarUrl);
    if (rawBytes != null) {
      avatarBytes = await _cropCircle(rawBytes);
    }

    return AndroidNotificationDetails(
      _alertChannelId,
      '家人提醒',
      channelDescription: '围栏、想你、聊天等提醒通知',
      importance: importance,
      priority: priority,
      autoCancel: true,
      showWhen: true,
      color: color,
      // largeIcon = 发送人头像圆形图片
      // 在通知中显示为：大头像在左 + 小应用图标角标在头像右下角（与微信一致）
      largeIcon: avatarBytes != null
          ? ByteArrayAndroidBitmap(avatarBytes)
          : null,
      // 使用 InboxStyle 展开时显示更多内容
      styleInformation: InboxStyleInformation(
        [messageText],
        contentTitle: userName,
        summaryText: null,
      ),
      enableVibration: enableVibration,
      vibrationPattern: vibrationPattern,
      playSound: playSound,
    );
  }

  // ==================== 各类通知 ====================

  /// 围栏通知
  Future<void> showGeofenceAlert({
    required String userName,
    required String action,
    required String fenceName,
    String? avatarUrl,
    double? latitude,
    double? longitude,
  }) async {
    final actionText = action == 'entered' ? '进入了' : '离开了';
    final payload = jsonEncode({
      'type': 'geofence',
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
    });
    final androidDetails = await _buildChatStyleDetails(
      userName: userName,
      messageText: '$actionText$fenceName',
      avatarUrl: avatarUrl,
      color: const Color(0xFF6366F1),
    );
    const iosDetails = DarwinNotificationDetails();
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    final id = _getNotificationId();
    await _plugin.show(id: id, title: userName, body: '$actionText$fenceName', notificationDetails: details, payload: payload);
  }

  /// SOS 紧急求助通知 — 点击定位到地图
  Future<void> showSosAlert({
    required String userName,
    String? address,
    String? avatarUrl,
    double? latitude,
    double? longitude,
  }) async {
    final body = address != null
        ? '发送了紧急求助！位置：$address'
        : '发送了紧急求助！';
    final payload = jsonEncode({
      'type': 'sos',
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
    });
    final androidDetails = await _buildChatStyleDetails(
      userName: userName,
      messageText: body,
      avatarUrl: avatarUrl,
      color: const Color(0xFFEF4444),
      importance: Importance.max,
      priority: Priority.max,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 500, 200, 500]),
      playSound: true,
    );
    const iosDetails = DarwinNotificationDetails();
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    await _plugin.show(id: _getNotificationId(), title: userName, body: body, notificationDetails: details, payload: payload);
  }

  /// 想你通知
  Future<void> showThinkingOfYou({
    required String fromUserName,
    String? fromUserAvatarUrl,
  }) async {
    final androidDetails = await _buildChatStyleDetails(
      userName: fromUserName,
      messageText: '想你了~',
      avatarUrl: fromUserAvatarUrl,
      color: const Color(0xFFEC4899),
    );
    const iosDetails = DarwinNotificationDetails();
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    await _plugin.show(id: _getNotificationId(), title: fromUserName, body: '想你了~', notificationDetails: details);
  }

  /// 聊天消息通知 — 点击跳转到群聊天
  Future<void> showChatMessage({
    required String userName,
    required String content,
    String? avatarUrl,
    String? circleId,
  }) async {
    // 语音消息格式: "url|duration"，检测并显示为[语音]
    final isVoice = content.contains('|') && content.startsWith('/uploads/audio');
    final displayContent = isVoice ? '[语音]' : content;
    final payload = circleId != null
        ? jsonEncode({'type': 'chat', 'circleId': circleId})
        : null;
    final androidDetails = await _buildChatStyleDetails(
      userName: userName,
      messageText: displayContent,
      avatarUrl: avatarUrl,
      color: const Color(0xFF6366F1),
    );
    const iosDetails = DarwinNotificationDetails();
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    await _plugin.show(id: _getNotificationId(), title: userName, body: displayContent, notificationDetails: details, payload: payload);
  }

  /// 通用通知
  Future<void> showAlert({
    required String title,
    required String body,
    int? id,
    String? avatarUrl,
  }) async {
    final androidDetails = await _buildChatStyleDetails(
      userName: title,
      messageText: body,
      avatarUrl: avatarUrl,
    );
    const iosDetails = DarwinNotificationDetails();
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    await _plugin.show(id: id ?? _getNotificationId(), title: title, body: body, notificationDetails: details);
  }
}
