import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 系统通知服务 — 常驻前台通知 + 围栏/SOS/想你等系统悬浮通知
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  /// 通知渠道 ID
  static const String _foregroundChannelId = 'familymap_foreground';
  static const String _alertChannelId = 'familymap_alerts';

  /// 前台通知 ID（固定，同一时间只有一个）
  static const int _foregroundNotificationId = 1000;

  bool _initialized = false;

  /// 初始化通知插件 + 创建通知渠道
  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    _initialized = true;
    debugPrint('[通知] 初始化完成');
  }

  /// 请求 Android 13+ 通知权限
  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;
    return await android.requestNotificationsPermission() ?? false;
  }

  /// 通知点击回调
  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('[通知] 点击了通知: id=${response.id}, payload=${response.payload}');
  }

  // ==================== 前台常驻通知 ====================

  /// 显示/更新前台服务常驻通知
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
      ongoing: true, // 常驻，不可左滑关闭
      autoCancel: false,
      showWhen: false,
      silent: true,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      id: _foregroundNotificationId,
      title: title,
      body: body,
      notificationDetails: details,
    );
    debugPrint('[通知] 前台常驻通知已显示: $title - $body');
  }

  /// 关闭前台常驻通知
  Future<void> cancelForegroundNotification() async {
    await _plugin.cancel(id: _foregroundNotificationId);
    debugPrint('[通知] 前台常驻通知已关闭');
  }

  // ==================== 系统提醒通知 ====================

  /// 围栏到达/离开通知
  Future<void> showGeofenceAlert({
    required String userName,
    required String action, // 'entered' | 'left'
    required String fenceName,
  }) async {
    final actionText = action == 'entered' ? '进入了' : '离开了';

    final androidDetails = AndroidNotificationDetails(
      _alertChannelId,
      '围栏提醒',
      channelDescription: '家人到达或离开围栏时提醒',
      importance: Importance.high, // 高重要性，弹出悬浮通知
      priority: Priority.high,
      autoCancel: true,
      showWhen: true,
      color: const Color(0xFF6366F1),
    );
    const iosDetails = DarwinNotificationDetails();
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    final id = (userName + action + fenceName).hashCode.abs() % 100000;
    await _plugin.show(
      id: id,
      title: '围栏提醒',
      body: '$userName $actionText $fenceName',
      notificationDetails: details,
    );
  }

  /// SOS 紧急求助通知
  Future<void> showSosAlert({
    required String userName,
    String? address,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      _alertChannelId,
      '围栏提醒',
      channelDescription: '家人到达或离开围栏时提醒',
      importance: Importance.max,
      priority: Priority.max,
      autoCancel: true,
      showWhen: true,
      color: const Color(0xFFEF4444),
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 500, 200, 500]),
      playSound: true,
    );
    const iosDetails = DarwinNotificationDetails();
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    final body = address != null
        ? '$userName 发送了紧急求助！位置：$address'
        : '$userName 发送了紧急求助！';
    await _plugin.show(
      id: 9999,
      title: 'SOS 紧急求助',
      body: body,
      notificationDetails: details,
    );
  }

  /// 想你通知
  Future<void> showThinkingOfYou({
    required String fromUserName,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      _alertChannelId,
      '围栏提醒',
      channelDescription: '家人到达或离开围栏时提醒',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      autoCancel: true,
      showWhen: true,
      color: Color(0xFFEC4899),
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _plugin.show(
      id: 8888,
      title: 'FamilyMap',
      body: '$fromUserName 想你了~',
      notificationDetails: details,
    );
  }

  /// 通用系统通知
  Future<void> showAlert({
    required String title,
    required String body,
    int? id,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      _alertChannelId,
      '围栏提醒',
      channelDescription: '家人到达或离开围栏时提醒',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      autoCancel: true,
      showWhen: true,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _plugin.show(
      id: id ?? body.hashCode.abs() % 100000,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }
}
