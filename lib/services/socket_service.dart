import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import '../models/models.dart';

/// Socket 服务 - 与后端 WebSocket 实时通信
/// 5.3 增强：指数退避重连 + 离线位置缓存补传 + 降级表现
class SocketService {
  IO.Socket? _socket;
  final String serverUrl;

  // 所有实时事件流
  final _locationController = StreamController<MemberLocation>.broadcast();
  final _onlineController = StreamController<String>.broadcast();
  final _offlineController = StreamController<String>.broadcast();
  final _geofenceAlertController = StreamController<Map<String, dynamic>>.broadcast();
  final _chatMessageController = StreamController<Message>.broadcast();
  final _sosAlertController = StreamController<SosAlert>.broadcast();
  final _emojiBombController = StreamController<Map<String, dynamic>>.broadcast();
  final _thinkingOfYouController = StreamController<Map<String, dynamic>>.broadcast();
  final _aliveWarningController = StreamController<Map<String, dynamic>>.broadcast();
  final _collisionAlertController = StreamController<Map<String, dynamic>>.broadcast();
  final _tripReportController = StreamController<Map<String, dynamic>>.broadcast();
  final _memberJoinedController = StreamController<Map<String, dynamic>>.broadcast();
  final _lowBatteryController = StreamController<Map<String, dynamic>>.broadcast();
  final _homeStatusController = StreamController<Map<String, dynamic>>.broadcast();

  SocketService({this.serverUrl = 'http://www.zhp0104.fun:8090'});

  // 对外暴露的 Stream
  Stream<MemberLocation> get onMemberLocation => _locationController.stream;
  Stream<String> get onMemberOnline => _onlineController.stream;
  Stream<String> get onMemberOffline => _offlineController.stream;
  Stream<Map<String, dynamic>> get onGeofenceAlert => _geofenceAlertController.stream;
  Stream<Message> get onChatMessage => _chatMessageController.stream;
  Stream<SosAlert> get onSosAlert => _sosAlertController.stream;
  Stream<Map<String, dynamic>> get onEmojiBomb => _emojiBombController.stream;
  Stream<Map<String, dynamic>> get onThinkingOfYou => _thinkingOfYouController.stream;
  Stream<Map<String, dynamic>> get onAliveWarning => _aliveWarningController.stream;
  Stream<Map<String, dynamic>> get onCollisionAlert => _collisionAlertController.stream;
  Stream<Map<String, dynamic>> get onTripReport => _tripReportController.stream;
  Stream<Map<String, dynamic>> get onMemberJoined => _memberJoinedController.stream;
  Stream<Map<String, dynamic>> get onLowBattery => _lowBatteryController.stream;
  Stream<Map<String, dynamic>> get onHomeStatus => _homeStatusController.stream;

  /// 是否已连接
  bool get isConnected => _socket?.connected == true;

  String? _userId;
  bool _isReconnecting = false;

  // 离线位置缓存：网络断开时暂存位置，恢复后批量发送
  final List<Map<String, dynamic>> _offlineBuffer = [];
  static const int _maxOfflineBuffer = 50;

  /// 连接到服务器（5.3 指数退避重连）
  void connect(String userId) {
    _userId = userId;
    _socket = IO.io(serverUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'reconnection': true,
      'reconnectionAttempts': 999999,
      'reconnectionDelay': 1000,     // 初始1秒
      'reconnectionDelayMax': 30000, // 最大30秒（指数退避上限）
      'randomizationFactor': 0.5,    // 随机抖动因子，防雷群效应
    });

    // 连接/重连时都重新发送上线事件和加入房间，并补传离线缓存
    _socket!.on('connect', (_) {
      _isReconnecting = false;
      if (_userId != null) {
        _socket!.emit('user:online', {'userId': _userId});
        _flushOfflineBuffer(); // 重连后补传离线缓存
      }
    });

    _socket!.on('disconnect', (_) {
      _isReconnecting = true;
    });

    // 位置更新
    _socket!.on('member:location', (data) {
      _locationController.add(MemberLocation.fromJson(Map<String, dynamic>.from(data)));
    });

    // 成员上线
    _socket!.on('member:online', (data) {
      _onlineController.add(data['userId'] as String);
    });

    // 成员离线
    _socket!.on('member:offline', (data) {
      _offlineController.add(data['userId'] as String);
    });

    // 围栏警报
    _socket!.on('geofence:alert', (data) {
      _geofenceAlertController.add(Map<String, dynamic>.from(data));
    });

    // 聊天消息
    _socket!.on('chat:message', (data) {
      _chatMessageController.add(Message.fromJson(Map<String, dynamic>.from(data)));
    });

    // SOS 警报
    _socket!.on('sos:alert', (data) {
      _sosAlertController.add(SosAlert.fromJson(Map<String, dynamic>.from(data)));
    });

    // 表情炸弹
    _socket!.on('emoji:bomb', (data) {
      _emojiBombController.add(Map<String, dynamic>.from(data));
    });

    // 想你通知
    _socket!.on('interaction:care', (data) {
      _thinkingOfYouController.add(Map<String, dynamic>.from(data));
    });

    // 存活警告（24小时无更新）
    _socket!.on('alive:warning', (data) {
      _aliveWarningController.add(Map<String, dynamic>.from(data));
    });

    // 碰撞警报（急减速）
    _socket!.on('collision:alert', (data) {
      _collisionAlertController.add(Map<String, dynamic>.from(data));
    });

    // 行程报告（离开某地）
    _socket!.on('trip:report', (data) {
      _tripReportController.add(Map<String, dynamic>.from(data));
    });

    // 成员加入圈子
    _socket!.on('circle:join', (data) {
      _memberJoinedController.add(Map<String, dynamic>.from(data));
    });

    // 低电量通知（4.4新功能）
    _socket!.on('battery:low', (data) {
      _lowBatteryController.add(Map<String, dynamic>.from(data));
    });

    // 4.6 到家/离家自动通知
    _socket!.on('home:status', (data) {
      _homeStatusController.add(Map<String, dynamic>.from(data));
    });
  }

  /// 发送位置更新（5.3 离线缓存：断线时暂存，重连后补传）
  void sendLocationUpdate({
    required String userId,
    required double latitude,
    required double longitude,
    double? accuracy,
    int? batteryLevel,
    bool? isCharging,
    double? speed,
  }) {
    final payload = {
      'userId': userId,
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'batteryLevel': batteryLevel,
      'isCharging': isCharging ?? false,
      'speed': speed,
    };

    if (_socket?.connected == true) {
      _socket!.emit('location:update', payload);
    } else {
      // 离线时缓存位置，重连后补传
      if (_offlineBuffer.length < _maxOfflineBuffer) {
        _offlineBuffer.add(payload);
      }
    }
  }

  /// 重连后补传离线缓存
  void _flushOfflineBuffer() {
    if (_offlineBuffer.isEmpty) return;
    final batch = List<Map<String, dynamic>>.from(_offlineBuffer);
    _offlineBuffer.clear();
    for (final payload in batch) {
      _socket?.emit('location:update', payload);
    }
    debugPrint('[Socket] 补传离线位置 ${batch.length} 条');
  }

  static void debugPrint(String msg) {
    // 简单日志输出
    print(msg);
  }

  /// 发送表情炸弹
  void sendEmojiBomb({required String userId, required String emoji, int count = 10}) {
    _socket?.emit('emoji:bomb', {'userId': userId, 'emoji': emoji, 'count': count});
  }

  /// 发送"想你"互动
  void sendThinkingOfYou({required String userId, String userName = ''}) {
    _socket?.emit('interaction:care', {'userId': userId, 'userName': userName});
  }

  /// 断开连接
  void disconnect() {
    _socket?.disconnect();
    _socket = null;
  }

  /// 释放资源
  void dispose() {
    _locationController.close();
    _onlineController.close();
    _offlineController.close();
    _geofenceAlertController.close();
    _chatMessageController.close();
    _sosAlertController.close();
    _emojiBombController.close();
    _thinkingOfYouController.close();
    _aliveWarningController.close();
    _collisionAlertController.close();
    _tripReportController.close();
    _memberJoinedController.close();
    _lowBatteryController.close();
  }
}
