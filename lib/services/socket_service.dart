import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import '../config.dart';
import '../models/models.dart';

/// Socket 服务 - 与后端 WebSocket 实时通信
/// 5.3 增强：指数退避重连 + 离线位置缓存补传 + 降级表现
/// 应用级单例：MapScreen 和 ChatScreen 共享同一实例，由 main.dart 管理生命周期
class SocketService {
  static SocketService? _instance;

  /// 获取单例实例
  static SocketService get instance => _instance ??= SocketService._internal();

  /// 内部构造函数
  SocketService._internal();
  bool _isDisposed = false; // 是否已释放

  /// 兼容旧代码的工厂构造（返回单例）
  factory SocketService({String? serverUrl}) => instance;

  IO.Socket? _socket;
  final String serverUrl = AppConfig.httpBaseUrl;

  // 所有实时事件流（非 final，支持重新登录时重建）
  StreamController<MemberLocation> _locationController = StreamController<MemberLocation>.broadcast();
  StreamController<String> _onlineController = StreamController<String>.broadcast();
  StreamController<String> _offlineController = StreamController<String>.broadcast();
  StreamController<Map<String, dynamic>> _geofenceAlertController = StreamController<Map<String, dynamic>>.broadcast();
  StreamController<Message> _chatMessageController = StreamController<Message>.broadcast();
  StreamController<SosAlert> _sosAlertController = StreamController<SosAlert>.broadcast();
  StreamController<Map<String, dynamic>> _emojiBombController = StreamController<Map<String, dynamic>>.broadcast();
  StreamController<Map<String, dynamic>> _thinkingOfYouController = StreamController<Map<String, dynamic>>.broadcast();
  StreamController<Map<String, dynamic>> _aliveWarningController = StreamController<Map<String, dynamic>>.broadcast();
  StreamController<Map<String, dynamic>> _collisionAlertController = StreamController<Map<String, dynamic>>.broadcast();
  StreamController<Map<String, dynamic>> _tripReportController = StreamController<Map<String, dynamic>>.broadcast();
  StreamController<Map<String, dynamic>> _memberJoinedController = StreamController<Map<String, dynamic>>.broadcast();
  StreamController<Map<String, dynamic>> _lowBatteryController = StreamController<Map<String, dynamic>>.broadcast();
  StreamController<Map<String, dynamic>> _homeStatusController = StreamController<Map<String, dynamic>>.broadcast();
  StreamController<Map<String, dynamic>> _forceLogoutController = StreamController<Map<String, dynamic>>.broadcast();

  /// 确保 Stream 控制器处于打开状态（重新登录后可能已被 dispose 关闭）
  void _ensureControllersOpen() {
    if (_locationController.isClosed) _locationController = StreamController<MemberLocation>.broadcast();
    if (_onlineController.isClosed) _onlineController = StreamController<String>.broadcast();
    if (_offlineController.isClosed) _offlineController = StreamController<String>.broadcast();
    if (_geofenceAlertController.isClosed) _geofenceAlertController = StreamController<Map<String, dynamic>>.broadcast();
    if (_chatMessageController.isClosed) _chatMessageController = StreamController<Message>.broadcast();
    if (_sosAlertController.isClosed) _sosAlertController = StreamController<SosAlert>.broadcast();
    if (_emojiBombController.isClosed) _emojiBombController = StreamController<Map<String, dynamic>>.broadcast();
    if (_thinkingOfYouController.isClosed) _thinkingOfYouController = StreamController<Map<String, dynamic>>.broadcast();
    if (_aliveWarningController.isClosed) _aliveWarningController = StreamController<Map<String, dynamic>>.broadcast();
    if (_collisionAlertController.isClosed) _collisionAlertController = StreamController<Map<String, dynamic>>.broadcast();
    if (_tripReportController.isClosed) _tripReportController = StreamController<Map<String, dynamic>>.broadcast();
    if (_memberJoinedController.isClosed) _memberJoinedController = StreamController<Map<String, dynamic>>.broadcast();
    if (_lowBatteryController.isClosed) _lowBatteryController = StreamController<Map<String, dynamic>>.broadcast();
    if (_homeStatusController.isClosed) _homeStatusController = StreamController<Map<String, dynamic>>.broadcast();
    if (_forceLogoutController.isClosed) _forceLogoutController = StreamController<Map<String, dynamic>>.broadcast();
  }

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
  Stream<Map<String, dynamic>> get onForceLogout => _forceLogoutController.stream;

  /// 是否已连接
  bool get isConnected => _socket?.connected == true;

  String? _userId;
  String? _sessionToken; // 会话 token
  bool _isReconnecting = false;

  // 离线位置缓存：网络断开时暂存位置，恢复后批量发送
  final List<Map<String, dynamic>> _offlineBuffer = [];
  static const int _maxOfflineBuffer = 50;

  /// 连接到服务器（5.3 指数退避重连），同时传 session token
  void connect(String userId, {String? token}) {
    // 修复：重新登录时重置 _isDisposed，允许重新连接
    _isDisposed = false;
    // 如果 Stream 已关闭（之前调用了 dispose），需要重建控制器
    _ensureControllersOpen();
    // 先断开旧连接，防止 socket 泄漏和重复事件
    _socket?.disconnect();
    _socket = null;
    _userId = userId;
    _sessionToken = token;
    _socket = IO.io(serverUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'reconnection': true,
      'reconnectionAttempts': 999999,
      'reconnectionDelay': 1000,     // 初始1秒
      'reconnectionDelayMax': 30000, // 最大30秒（指数退避上限）
      'randomizationFactor': 0.5,    // 随机抖动因子，防雷群效应
      'auth': {'token': _sessionToken}, // 通过 auth 传 token
      'secure': true,
      'badCertificateCallback': (cert, host, port) {
        return host == AppConfig.serverHost;
      },
    });

    // 连接/重连时都重新发送上线事件和加入房间，并补传离线缓存
    _socket!.on('connect', (_) {
      _isReconnecting = false;
      if (_userId != null) {
        _socket!.emit('user:online', {
          'userId': _userId,
        });
        _flushOfflineBuffer(); // 重连后补传离线缓存
      }
    });

    _socket!.on('disconnect', (_) {
      _isReconnecting = true;
    });

    // 位置更新
    _socket!.on('member:location', (data) {
      if (!_locationController.isClosed) {
        _locationController.add(MemberLocation.fromJson(Map<String, dynamic>.from(data)));
      }
    });

    // 成员上线
    _socket!.on('member:online', (data) {
      if (!_onlineController.isClosed) {
        _onlineController.add(data['userId'] as String);
      }
    });

    // 成员离线
    _socket!.on('member:offline', (data) {
      if (!_offlineController.isClosed) {
        _offlineController.add(data['userId'] as String);
      }
    });

    // 围栏警报
    _socket!.on('geofence:alert', (data) {
      if (!_geofenceAlertController.isClosed) {
        _geofenceAlertController.add(Map<String, dynamic>.from(data));
      }
    });

    // 聊天消息
    _socket!.on('chat:message', (data) {
      if (!_chatMessageController.isClosed) {
        _chatMessageController.add(Message.fromJson(Map<String, dynamic>.from(data)));
      }
    });

    // SOS 警报
    _socket!.on('sos:alert', (data) {
      if (!_sosAlertController.isClosed) {
        _sosAlertController.add(SosAlert.fromJson(Map<String, dynamic>.from(data)));
      }
    });

    // 表情炸弹
    _socket!.on('emoji:bomb', (data) {
      if (!_emojiBombController.isClosed) {
        _emojiBombController.add(Map<String, dynamic>.from(data));
      }
    });

    // 想你通知
    _socket!.on('interaction:care', (data) {
      if (!_thinkingOfYouController.isClosed) {
        _thinkingOfYouController.add(Map<String, dynamic>.from(data));
      }
    });

    // 存活警告（24小时无更新）
    _socket!.on('alive:warning', (data) {
      if (!_aliveWarningController.isClosed) {
        _aliveWarningController.add(Map<String, dynamic>.from(data));
      }
    });

    // 碰撞警报（急减速）
    _socket!.on('collision:alert', (data) {
      if (!_collisionAlertController.isClosed) {
        _collisionAlertController.add(Map<String, dynamic>.from(data));
      }
    });

    // 行程报告（离开某地）
    _socket!.on('trip:report', (data) {
      if (!_tripReportController.isClosed) {
        _tripReportController.add(Map<String, dynamic>.from(data));
      }
    });

    // 成员加入圈子
    _socket!.on('circle:join', (data) {
      if (!_memberJoinedController.isClosed) {
        _memberJoinedController.add(Map<String, dynamic>.from(data));
      }
    });

    // 低电量通知（4.4新功能）
    _socket!.on('battery:low', (data) {
      if (!_lowBatteryController.isClosed) {
        _lowBatteryController.add(Map<String, dynamic>.from(data));
      }
    });

    // 4.6 到家/离家自动通知
    _socket!.on('home:status', (data) {
      if (!_homeStatusController.isClosed) {
        _homeStatusController.add(Map<String, dynamic>.from(data));
      }
    });

    // 多设备互踢：收到强制登出通知
    _socket!.on('force_logout', (data) {
      print('[Socket] 收到 force_logout: $data');
      if (!_forceLogoutController.isClosed) {
        _forceLogoutController.add(Map<String, dynamic>.from(data));
      }
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
    print('[Socket] 补传离线位置 ${batch.length} 条');
  }

  /// 发送表情炸弹
  void sendEmojiBomb({required String userId, required String emoji, int count = 10}) {
    _socket?.emit('emoji:bomb', {'userId': userId, 'emoji': emoji, 'count': count});
  }

  /// 发送"想你"互动
  void sendThinkingOfYou({required String userId, String userName = '', String? targetUserId}) {
    _socket?.emit('interaction:care', {'userId': userId, 'userName': userName, 'targetUserId': targetUserId});
  }

  /// 断开连接（页面级调用，只断开 Socket，不关闭 Stream）
  void disconnect() {
    _socket?.disconnect();
    _socket = null;
  }

  /// 释放资源（应用退出时由 main.dart 调用，页面不要调用）
  void dispose() {
    _isDisposed = true;
    disconnect();
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
    _homeStatusController.close();
    _forceLogoutController.close();
  }
}
