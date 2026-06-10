import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Circle;
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart';
import 'package:activity_recognition_flutter/activity_recognition_flutter.dart' as ar;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../services/socket_service.dart';
import '../services/api_service.dart';
import '../services/gps_debug_logger.dart';
import '../widgets/trail_particles.dart';
import '../widgets/member_marker.dart';
import '../widgets/sim_controller.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';
import 'footprint_screen.dart';
import 'timeline_screen.dart';

/// 主地图页面 - FamilyMap 核心界面
class MapScreen extends StatefulWidget {
  final AppUser currentUser;
  final bool darkMode;
  final Function(bool) onDarkModeChanged;

  const MapScreen({super.key, required this.currentUser, this.darkMode = false, required this.onDarkModeChanged});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  final SocketService _socketService = SocketService();
  final ApiService _apiService = ApiService();

  List<Circle> _circles = [];
  Circle? _currentCircle;
  Map<String, MemberTrail> _memberTrails = {};
  List<Map<String, dynamic>> _members = [];
  Set<String> _onlineMembers = {}; // 在线成员ID集合
  List<Geofence> _geofences = [];
  UserSettings? _userSettings;
  Position? _currentPosition;
  bool _isLocationSharing = false;
  StreamSubscription<Position>? _positionStream;
  Timer? _periodicSendTimer; // 定时发送位置，确保实时同步
  Timer? _memberRefreshTimer; // 定时刷新成员列表，获取最新地址
  Timer? _geocodeDebounce; // 逆地理解码防抖
  Timer? _stayTimer; // 每分钟刷新停留时长显示
  Timer? _gpsRetryTimer; // GPS权限/服务等待重试
  String _myAddress = ''; // 自己的逆地理地址
  int _currentTab = 0;

  // 活动识别（对标Jagat，用系统API判断是否在开车/步行/静止）
  StreamSubscription<ar.ActivityEvent>? _activityStream;
  ar.ActivityType _currentActivity = ar.ActivityType.unknown;
  ar.ActivityType _pendingActivity = ar.ActivityType.unknown;
  int _activityConfidenceCount = 0;
  static const int _activityConfidenceThreshold = 3; // 连续3次相同才切换

  // 1.4 速度滑动窗口（5点平均，过滤GPS噪声）
  final List<double> _speedWindow = [];
  static const int _speedWindowSize = 9;

  // 1.1 自适应上报频率：根据移动状态动态调整定时器间隔
  // 静止30s，步行/骑行10s，驾车3-5s
  Duration _currentReportInterval = const Duration(seconds: 10);
  Position? _lastReportedPosition; // 上次上报位置，用于GPS跳点检测

  // 围栏创建：长按地图选点
  LatLng? _geofencePinPos; // 围栏钉子位置（GCJ-02）
  bool _isPlacingGeofence = false; // 是否在选择围栏位置

  // 4.5 热力图
  bool _showHeatmap = false; // 是否显示热力图
  List<Map<String, dynamic>> _heatmapPoints = []; // 热力图数据点

  // GPS调试
  bool _gpsDebugEnabled = false;
  // GPS初始化状态追踪
  String _gpsInitStatus = '未初始化'; // 供调试框显示
  bool _gpsStreamActive = false; // 位置流是否已启动

  // 模拟驾驶模式（室内测试拖尾/测速/碰撞检测）
  bool _simMode = false;
  double _simBearing = 0;       // 当前模拟方位角（度）
  double _simSpeedMs = 1.5;     // 当前模拟速度 m/s
  bool _simMoving = false;      // 摇杆是否按下
  Timer? _simTimer;             // 模拟位置生成定时器

  // 可拖动底部面板 - 三档弹簧吸附
  double _panelHeight = 100;
  static const double _panelPeek = 100;   // 只显示Tab栏
  static const double _panelHalf = 260;   // 半屏
  static const double _panelFull = 500;   // 全屏
  double _dragStartY = 0;
  double _dragStartHeight = 0;

  /// 吸附到最近的档位（弹簧效果）
  void _snapPanel() {
    // 计算距离每个档位的距离
    final distances = [
      (_panelPeek, (_panelHeight - _panelPeek).abs()),
      (_panelHalf, (_panelHeight - _panelHalf).abs()),
      (_panelFull, (_panelHeight - _panelFull).abs()),
    ];
    distances.sort((a, b) => a.$2.compareTo(b.$2));
    final target = distances.first.$1;
    // 用 SpringSimulation 弹簧吸附
    _animatePanelTo(target);
  }

  /// 弹簧动画到目标高度
  void _animatePanelTo(double target) {
    // 使用 SpringAnimation 模拟弹簧效果
    // Flutter 没有直接的 SpringAnimation widget，用 AnimatedContainer + Curves.easeOut 代替
    // 但我们可以用 AnimationController + SpringSimulation 做真正的弹簧
    setState(() => _panelHeight = target);
  }

  // 表情炸弹动画
  List<_EmojiParticle> _emojiParticles = [];

  /// 是否处于暗黑模式（统一判断入口）
  bool get _isDark => widget.darkMode || _userSettings?.darkMode == true;

  @override
  void initState() {
    super.initState();
    _initLocation();
    _loadCircles();
    _loadSettings();
    _loadGpsDebugFlag(); // 读取GPS调试开关
    _onlineMembers.add(widget.currentUser.id); // 自己在线
    _socketService.connect(widget.currentUser.id);
    _listenSocketEvents();
    _initActivityRecognition();
  }

  Future<void> _loadGpsDebugFlag() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('gps_debug') ?? false;
    GpsDebugLogger.instance.enabled = enabled;
    if (mounted) setState(() => _gpsDebugEnabled = enabled);
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _periodicSendTimer?.cancel();
    _memberRefreshTimer?.cancel();
    _geocodeDebounce?.cancel();
    _stayTimer?.cancel();
    _gpsRetryTimer?.cancel();
    _simTimer?.cancel();
    _activityStream?.cancel();
    _socketService.disconnect();
    _socketService.dispose();
    super.dispose();
  }

  // ==================== 初始化 ====================

  Future<void> _initLocation() async {
    _gpsInitStatus = '正在检查GPS服务…';
    if (mounted) setState(() {});

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _gpsInitStatus = 'GPS未开启，等待用户打开…';
      if (mounted) setState(() {});
      _waitForLocationService();
      return;
    }

    _gpsInitStatus = '正在检查定位权限…';
    if (mounted) setState(() {});

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      _gpsInitStatus = '正在请求定位权限…';
      if (mounted) setState(() {});
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      _gpsInitStatus = '定位权限被永久拒绝，请在系统设置中手动开启';
      if (mounted) setState(() {});
      // 定时重新检查权限（用户可能去设置改了权限后回来）
      _waitForPermissionFix();
      return;
    }
    if (permission == LocationPermission.denied) {
      _gpsInitStatus = '定位权限被拒绝，3秒后重试…';
      if (mounted) setState(() {});
      Future.delayed(const Duration(seconds: 3), () => _initLocation());
      return;
    }

    _gpsInitStatus = '正在获取GPS定位…';
    if (mounted) setState(() {});

    // 带超时获取位置，避免GPS信号弱时无限等待
    Position? pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
    } catch (e) {
      debugPrint('[定位] getCurrentPosition失败: $e');
      // 超时或失败，尝试获取最后已知位置
      try {
        pos = await Geolocator.getLastKnownPosition();
        if (pos != null) {
          debugPrint('[定位] 使用最后已知位置: ${pos.latitude}, ${pos.longitude}');
        }
      } catch (e2) {
        debugPrint('[定位] getLastKnownPosition也失败: $e2');
      }
    }

    if (pos != null) {
      setState(() => _currentPosition = pos);
      final gcjPos = _wgs84ToGcj02(pos.latitude, pos.longitude);
      _mapController.move(gcjPos, 15);

      // 立即显示自己的标记（使用GCJ-02坐标）
      final myKey = widget.currentUser.id;
      _memberTrails[myKey] = MemberTrail(
        userId: myKey,
        name: widget.currentUser.name,
        color: _parseColor(widget.currentUser.avatarColor),
        currentPos: gcjPos,
      );

      _gpsInitStatus = 'GPS已定位（精度${pos.accuracy.toStringAsFixed(0)}m）';
    } else {
      _gpsInitStatus = 'GPS信号弱，位置流等待中…';
    }
    if (mounted) setState(() {});

    // 无论是否拿到当前位置，都启动位置流
    _startLocationSharing();

    // 如果拿到了位置，立即发送到服务器
    if (pos != null && _userSettings?.sharePaused != true) {
      _socketService.sendLocationUpdate(
        userId: widget.currentUser.id,
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracy: pos.accuracy,
        speed: pos.speed,
      );
    }
  }

  /// 等待GPS服务开启后自动初始化定位
  void _waitForLocationService() {
    _gpsRetryTimer?.cancel();
    _gpsRetryTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (enabled) {
        timer.cancel();
        _initLocation();
      }
    });
  }

  /// 等待用户修复权限后重试
  void _waitForPermissionFix() {
    _gpsRetryTimer?.cancel();
    _gpsRetryTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!mounted) { timer.cancel(); return; }
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.deniedForever &&
          permission != LocationPermission.denied) {
        timer.cancel();
        _initLocation();
      }
    });
  }

  Future<void> _loadSettings() async {
    try {
      final s = await _apiService.getUserSettings(widget.currentUser.id);
      setState(() => _userSettings = s);
      // 同步暗黑模式到全局主题（确保服务器设置与App主题一致）
      if (s.darkMode != widget.darkMode) {
        widget.onDarkModeChanged(s.darkMode);
      }
    } catch (_) {}
  }

  /// 4.5 加载热力图数据（当前用户，默认近7天）
  Future<void> _loadHeatmap() async {
    try {
      final data = await _apiService.getHeatmap(widget.currentUser.id, days: 7);
      final points = (data['heatmap'] as List).cast<Map<String, dynamic>>();
      setState(() => _heatmapPoints = points);
    } catch (e) {
      debugPrint('热力图加载失败: $e');
    }
  }

  /// 切换热力图显示
  void _toggleHeatmap() {
    setState(() => _showHeatmap = !_showHeatmap);
    if (_showHeatmap && _heatmapPoints.isEmpty) {
      _loadHeatmap();
    }
  }

  // ==================== 活动识别（对标Jagat）====================

  /// 初始化活动识别，监听系统对用户当前活动类型的判断
  Future<void> _initActivityRecognition() async {
    try {
      final activityRecognition = ar.ActivityRecognition();
      final stream = activityRecognition.activityStream(runForegroundService: false);
      _activityStream = stream.listen((event) {
        _onActivityEvent(event);
      });
    } catch (e) {
      debugPrint('活动识别不可用: $e');
    }
  }

  void _onActivityEvent(ar.ActivityEvent event) {
    // 置信度过滤：同一活动类型连续出现N次才切换
    if (event.type == _pendingActivity) {
      _activityConfidenceCount++;
    } else {
      _pendingActivity = event.type;
      _activityConfidenceCount = 1;
    }

    if (_activityConfidenceCount >= _activityConfidenceThreshold && _pendingActivity != _currentActivity) {
      setState(() {
        _currentActivity = _pendingActivity;
      });
      debugPrint('活动切换: $_currentActivity (置信度=$_activityConfidenceCount)');
    }
  }

  /// 根据活动识别判断移动类型（优化阈值：步行1.0/骑行3.5/驾车8m/s）
  MovementType _getMovementType() {
    switch (_currentActivity) {
      case ar.ActivityType.inVehicle:
        return MovementType.driving;
      case ar.ActivityType.onBicycle:
        return MovementType.cycling;
      case ar.ActivityType.onFoot:
      case ar.ActivityType.walking:
      case ar.ActivityType.running:
        return MovementType.walking;
      case ar.ActivityType.still:
        return MovementType.still;
      default:
        // 活动识别不可用时，用滑动窗口平均速度判断
        final avgSpeed = _getAverageSpeed();
        if (avgSpeed < 1.0) return MovementType.still;    // 1.0m/s ≈ 3.6km/h
        if (avgSpeed < 3.5) return MovementType.walking;   // 3.5m/s ≈ 12.6km/h
        if (avgSpeed < 8.0) return MovementType.cycling;   // 8.0m/s ≈ 28.8km/h
        return MovementType.driving;
    }
  }

  /// 获取滑动窗口平均速度（5点平滑，过滤GPS噪声）
  double _getAverageSpeed() {
    if (_speedWindow.isEmpty) return _currentPosition?.speed ?? 0.0;
    final sum = _speedWindow.fold<double>(0.0, (a, b) => a + b);
    return sum / _speedWindow.length;
  }

  /// 获取当前有效速度（模拟模式直接用设定值，否则走滑动窗口）
  double get _effectiveSpeed => _simMode ? _simSpeedMs : (_isCurrentlyMoving ? _getAverageSpeed() : 0.0);

  /// 当前是否在移动（活动识别 + 滑动窗口速度双判断）
  bool get _isCurrentlyMoving {
    // 活动识别明确在移动
    if (_currentActivity == ar.ActivityType.inVehicle ||
        _currentActivity == ar.ActivityType.onBicycle ||
        _currentActivity == ar.ActivityType.onFoot ||
        _currentActivity == ar.ActivityType.walking ||
        _currentActivity == ar.ActivityType.running) {
      return true;
    }
    // unknown/still 时用滑动窗口平均速度判断（比单点更稳定）
    if (_currentActivity == ar.ActivityType.unknown ||
        _currentActivity == ar.ActivityType.still) {
      return _getAverageSpeed() > 1.0; // 1.0m/s ≈ 3.6km/h，散步起步
    }
    return false;
  }

  // ==================== 位置共享 ====================

  void _startLocationSharing() {
    if (_isLocationSharing) return;
    _isLocationSharing = true;
    _gpsStreamActive = true;

    // 监听GPS位置变化
    // Android 14+ 需要用 AndroidSettings 确保位置流可靠
    _positionStream = Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0, // 不过滤，每次GPS更新都接收
      ),
    ).listen(
      (pos) {
        if (!_gpsStreamActive) {
          _gpsStreamActive = true;
          _gpsInitStatus = 'GPS已定位（精度${pos.accuracy.toStringAsFixed(0)}m）';
        }
        _handlePositionUpdate(pos);
      },
      onError: (e) {
        debugPrint('[定位] 位置流出错: $e');
        _gpsStreamActive = false;
        _gpsInitStatus = '位置流出错: $e，5秒后重试';
        if (mounted) setState(() {});
        _isLocationSharing = false;
        _positionStream?.cancel();
        Future.delayed(const Duration(seconds: 5), () => _startLocationSharing());
      },
      cancelOnError: false,
    );

    // 自适应上报定时器：根据移动状态动态调整间隔
    _periodicSendTimer?.cancel();
    _periodicSendTimer = Timer.periodic(_currentReportInterval, (_) {
      if (_currentPosition != null && _userSettings?.sharePaused != true) {
        _socketService.sendLocationUpdate(
          userId: widget.currentUser.id,
          latitude: _currentPosition!.latitude,
          longitude: _currentPosition!.longitude,
          accuracy: _currentPosition!.accuracy,
          speed: _effectiveSpeed,
        );
      }
    });

    // 每30秒刷新成员列表
    _memberRefreshTimer?.cancel();
    _memberRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _loadMembers();
    });

    // 每分钟刷新 UI，让停留时长实时递增
    _stayTimer?.cancel();
    _stayTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _members.any((m) => m['stay_started_at'] != null)) {
        setState(() {}); // 重新构建 UI，stay_minutes 会基于 stay_started_at 实时计算
      }
    });
  }

  /// 更新自适应上报频率（根据移动状态）
  void _updateReportInterval() {
    final moveType = _getMovementType();
    Duration newInterval;
    switch (moveType) {
      case MovementType.driving:
        newInterval = const Duration(seconds: 4); // 驾车4秒
        break;
      case MovementType.cycling:
      case MovementType.walking:
        newInterval = const Duration(seconds: 10); // 步行/骑行10秒
        break;
      case MovementType.still:
        newInterval = const Duration(seconds: 30); // 静止30秒
        break;
    }

    if (newInterval != _currentReportInterval) {
      _currentReportInterval = newInterval;
      // 重启定时器
      _periodicSendTimer?.cancel();
      _periodicSendTimer = Timer.periodic(_currentReportInterval, (_) {
        if (_currentPosition != null && _userSettings?.sharePaused != true) {
          _socketService.sendLocationUpdate(
            userId: widget.currentUser.id,
            latitude: _currentPosition!.latitude,
            longitude: _currentPosition!.longitude,
            accuracy: _currentPosition!.accuracy,
            speed: _effectiveSpeed,
          );
        }
      });
      debugPrint('[自适应] 上报间隔已调整为: ${newInterval.inSeconds}秒 (${moveType.name})');
    }
  }

  /// 处理位置更新（GPS流 + 定时发送共用）
  void _handlePositionUpdate(Position pos, {bool forceUpdate = false}) {
    // 收到位置更新，更新GPS状态
    _gpsInitStatus = 'GPS已定位（精度${pos.accuracy.toStringAsFixed(0)}m）';

    // 1.1 GPS跳点检测：如果与上次位置的距离/时间差 > 150km/h，丢弃
    if (_lastReportedPosition != null && !forceUpdate) {
      final dist = const Distance().distance(
        LatLng(_lastReportedPosition!.latitude, _lastReportedPosition!.longitude),
        LatLng(pos.latitude, pos.longitude),
      );
      final dt = pos.timestamp.difference(_lastReportedPosition!.timestamp).inMilliseconds / 1000;
      if (dt > 0 && dist / dt > 41.7) { // 41.7m/s = 150km/h
        debugPrint('[GPS] 跳点丢弃: ${dist}m/${dt}s = ${(dist/dt*3.6).toStringAsFixed(0)}km/h');
        return; // 丢弃GPS跳点
      }
    }

    setState(() => _currentPosition = pos);

    // GPS调试：始终更新快照（调试框依赖它），日志只在开启时记录
    final entry = GpsLogEntry(
      time: pos.timestamp,
      lat: pos.latitude,
      lng: pos.longitude,
      accuracy: pos.accuracy,
      speed: pos.speed,
      heading: pos.heading,
      isMocked: pos.isMocked,
      activity: _currentActivity.name,
    );
    GpsDebugLogger.instance.currentSnapshot = entry;
    if (GpsDebugLogger.instance.enabled) {
      GpsDebugLogger.instance.log(entry);
    }

    // 2. 仅非模拟模式下更新速度滑动窗口（模拟模式用 _simSpeedMs 直接上报）
    if (!_simMode && pos.accuracy <= 50) {
      _speedWindow.add(pos.speed);
      if (_speedWindow.length > _speedWindowSize) {
        _speedWindow.removeAt(0);
      }
    }

    // 暂停共享时不发送位置
    if (_userSettings?.sharePaused == true) return;

    // 自适应上报频率：检查是否需要调整
    _updateReportInterval();

    // 模拟模式直接用设定速度，不走滑动窗口平均
    final effectiveSpeed = _effectiveSpeed;

    _socketService.sendLocationUpdate(
      userId: widget.currentUser.id,
      latitude: pos.latitude,
      longitude: pos.longitude,
      accuracy: pos.accuracy,
      speed: effectiveSpeed, // 使用滑动窗口平均速度
    );
    _lastReportedPosition = pos;

    // 逆地理解码防抖：位置更新时延迟2秒后调一次API获取自己的地址
    _geocodeDebounce?.cancel();
    _geocodeDebounce = Timer(const Duration(seconds: 2), () async {
      try {
        final result = await _apiService.reverseGeocode(pos.latitude, pos.longitude);
        // 优先用完整 address（如"浙江省台州市椒江区章安街道竹岙村"），formatted 只有街道名
        final addr = (result['address'] as String?)?.isNotEmpty == true
            ? result['address'] as String
            : (result['formatted'] as String? ?? '');
        debugPrint('[Geocode] 自己的逆地理结果: addr="$addr", formatted=${result['formatted']}, address=${result['address']}');
        if (addr.isNotEmpty && mounted) {
          setState(() {
            _myAddress = addr;
            final idx = _members.indexWhere((m) => m['id'] == widget.currentUser.id);
            if (idx >= 0) {
              _members[idx]['address'] = addr;
              debugPrint('[Geocode] 已更新 _members[$idx].address = "$addr"');
            } else {
              debugPrint('[Geocode] 自己不在 _members 中，无法更新地址');
            }
          });
        } else {
          debugPrint('[Geocode] 逆地理结果为空，未更新');
        }
      } catch (e) {
        debugPrint('[Geocode] 异常: $e');
      }
    });

    // 更新自己的trail（使用GCJ-02坐标显示在地图上）
    final myKey = widget.currentUser.id;
    final gcjPos = _wgs84ToGcj02(pos.latitude, pos.longitude);
    final movementType = _getMovementType();

    if (_memberTrails.containsKey(myKey)) {
      final trail = _memberTrails[myKey]!;
      trail.updatePosition(gcjPos, gpsSpeed: effectiveSpeed);
      trail.overrideMovementType = movementType;
    } else {
      final trail = MemberTrail(
        userId: myKey,
        name: widget.currentUser.name,
        color: _parseColor(widget.currentUser.avatarColor),
        currentPos: gcjPos,
        speed: effectiveSpeed,
      );
      trail.overrideMovementType = movementType;
      _memberTrails[myKey] = trail;
    }
  }

  // ==================== Socket 事件监听 ====================

  void _listenSocketEvents() {
    // 成员位置更新
    _socketService.onMemberLocation.listen((loc) {
      debugPrint('[Socket] member:location: userId=${loc.userId}, address=${loc.address}, lat=${loc.latitude}, lng=${loc.longitude}');
      setState(() {
        // 更新 _members 中的地址和电量等字段（自己也处理，服务器已补发自发自收）
        final idx = _members.indexWhere((m) => m['id'] == loc.userId);
        if (idx >= 0) {
          final newAddr = loc.address ?? '';
          final existingAddr = _members[idx]['address'] as String? ?? '';
          debugPrint('[Socket]   成员 ${_members[idx]['name']}: 旧地址="$existingAddr", 新地址="$newAddr"');
          // 优先用真实地址，如果新地址是坐标降级格式则保留旧的
          final isCoordFallback = newAddr.startsWith('位置(') || RegExp(r'^\d+\.\d+,\s*\d+\.\d+$').hasMatch(newAddr);
          if (newAddr.isNotEmpty && !isCoordFallback) {
            _members[idx]['address'] = newAddr;
          } else if (existingAddr.isEmpty && newAddr.isNotEmpty) {
            _members[idx]['address'] = newAddr;
          }
          _members[idx]['battery_level'] = loc.batteryLevel ?? _members[idx]['battery_level'];
          _members[idx]['is_charging'] = loc.isCharging == true ? 1 : _members[idx]['is_charging'];
          _members[idx]['speed'] = loc.speed ?? _members[idx]['speed'];
          // 二.1 地址智能切换：从静止变为移动时，清除 stay_address，避免显示过期停留地名
          final speed = loc.speed ?? 0.0;
          if (speed > 1.0) {
            _members[idx]['stay_address'] = null;
            _members[idx]['stay_minutes'] = null;
          } else {
            // 静止时，使用服务端推送的实时停留信息
            final locStayAddr = loc.stayAddress;
            final locStayMins = loc.stayMinutes;
            if (locStayAddr != null) _members[idx]['stay_address'] = locStayAddr;
            if (locStayMins != null) _members[idx]['stay_minutes'] = locStayMins;
            // 保存停留开始时间，前端可实时计算时长
            if (loc.stayStartedAt != null) {
              _members[idx]['stay_started_at'] = loc.stayStartedAt!.toIso8601String();
            }
          }
          // 二.3 同步幽灵模式标识
          if (loc.ghostMode != null) {
            _members[idx]['ghost_mode'] = loc.ghostMode;
          }
        }

        final name = idx >= 0 ? (_members[idx]['name'] ?? '未知') : '未知';
        final color = idx >= 0 ? _parseColor(_members[idx]['avatar_color'] ?? '#64748B') : _parseColor('#64748B');
        final gcjPos = _wgs84ToGcj02(loc.latitude, loc.longitude);

        if (_memberTrails.containsKey(loc.userId)) {
          _memberTrails[loc.userId]!.updatePosition(gcjPos, gpsSpeed: loc.speed);
        } else {
          _memberTrails[loc.userId] = MemberTrail(
            userId: loc.userId,
            name: name,
            color: color,
            currentPos: gcjPos,
            speed: loc.speed ?? 0,
            lastUpdate: loc.recordedAt,
          );
        }
      });
    });

    // 成员上线
    _socketService.onMemberOnline.listen((userId) {
      if (!mounted) return;
      setState(() {
        _onlineMembers.add(userId);
      });
      debugPrint('[Online] $userId 上线');
      _loadMembers();
    });

    // 成员离线
    _socketService.onMemberOffline.listen((userId) {
      if (!mounted) return;
      setState(() {
        _onlineMembers.remove(userId);
      });
      debugPrint('[Online] $userId 离线');
    });

    // 围栏警报
    _socketService.onGeofenceAlert.listen((data) {
      if (!mounted) return;
      _showNotification(
        '${data['userName']} ${data['action'] == 'entered' ? '进入' : '离开'}了 ${data['fenceName']}',
        icon: data['action'] == 'entered' ? Icons.login : Icons.logout,
      );
    });

    // 聊天消息
    _socketService.onChatMessage.listen((msg) {
      if (!mounted) return;
      if (msg.userId == widget.currentUser.id) return;
      _showNotification(
        '${msg.userName}: ${msg.content}',
        icon: Icons.chat_bubble,
      );
    });

    // SOS 警报
    _socketService.onSosAlert.listen((alert) {
      if (!mounted) return;
      _vibrate();
      _showSosDialog(alert);
    });

    // 表情炸弹
    _socketService.onEmojiBomb.listen((data) {
      if (!mounted) return;
      _triggerEmojiBomb(data['emoji'] ?? '❤️', (data['count'] ?? 10) as int);
    });

    // 想你通知
    _socketService.onThinkingOfYou.listen((data) {
      if (!mounted) return;
      _showNotification(
        '${data['fromUserName']} 想你了~',
        icon: Icons.favorite,
        color: const Color(0xFFEC4899),
      );
    });

    // 存活警告（P1提升：弹出确认对话框而非仅SnackBar）
    _socketService.onAliveWarning.listen((data) {
      if (!mounted) return;
      final userName = data['userName'] as String? ?? '某人';
      final hours = data['hours'] ?? 24;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Row(children: [
            const Icon(Icons.warning_amber, color: Colors.orange, size: 28),
            const SizedBox(width: 8),
            Text('$userName 失联警告'),
          ]),
          content: Text('$userName 已超过 $hours 小时没有更新位置，可能手机关机或信号中断，建议联系确认安全。'),
          actions: [
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _socketService.sendThinkingOfYou(
                  userId: widget.currentUser.id,
                  userName: widget.currentUser.name,
                );
                _showNotification('已发送关怀消息给 $userName');
              },
              icon: const Icon(Icons.favorite, color: Colors.orange),
              label: const Text('发送关怀'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
    });

    // 碰撞警报（1.5改进：全屏红色警告卡片 + 拨打电话/发送关怀按钮）
    _socketService.onCollisionAlert.listen((data) {
      if (!mounted) return;
      _vibrate();
      _showCollisionAlert(data);
    });

    // 行程报告
    _socketService.onTripReport.listen((data) {
      if (!mounted) return;
      _showNotification(
        '${data['userName']} ${data['action'] == 'left' ? '离开了' : '到达了'} ${data['address']}（停留${data['duration']}分钟）',
        icon: Icons.trip_origin,
      );
    });

    // 成员加入圈子 - 刷新成员列表和圈子列表
    _socketService.onMemberJoined.listen((data) {
      if (!mounted) return;
      _loadMembers();
      _loadCircles();
      _showNotification(
        '${data['userName']} 加入了圈子',
        icon: Icons.person_add,
      );
    });

    // 低电量自动通知（4.4新功能）
    _socketService.onLowBattery.listen((data) {
      if (!mounted) return;
      _showNotification(
        '${data['userName']} 电量仅剩 ${data['batteryLevel']}%！',
        icon: Icons.battery_alert,
        color: Colors.orange,
      );
    });

    // 4.6 到家/离家自动通知
    _socketService.onHomeStatus.listen((data) {
      if (!mounted) return;
      final action = data['action'] as String? ?? '';
      final userName = data['userName'] as String? ?? '某人';
      if (action == 'arrived') {
        _showNotification(
          '$userName 已到家',
          icon: Icons.home,
          color: const Color(0xFF10B981), // 绿色
        );
      } else if (action == 'left') {
        _showNotification(
          '$userName 已离家',
          icon: Icons.directions_walk,
          color: const Color(0xFF6366F1), // 紫色
        );
      }
    });
  }

  // ==================== 数据加载 ====================

  Future<void> _loadCircles() async {
    try {
      final circles = await _apiService.getUserCircles(widget.currentUser.id);
      debugPrint('[Circles] 用户 ${widget.currentUser.id} 有 ${circles.length} 个圈子');
      setState(() => _circles = circles);
      if (circles.isNotEmpty && _currentCircle == null) {
        debugPrint('[Circles] 自动选择圈子: ${circles.first.name} (${circles.first.id})');
        _selectCircle(circles.first);
      } else if (circles.isEmpty) {
        debugPrint('[Circles] 没有圈子，需要创建或加入');
      }
    } catch (e) {
      debugPrint('加载圈子失败: $e');
    }
  }

  Future<void> _selectCircle(Circle circle) async {
    setState(() => _currentCircle = circle);
    await _loadMembers();
    await _loadGeofences();
    _startLocationSharing();
  }

  Future<void> _loadMembers() async {
    if (_currentCircle == null) return;
    try {
      final members = await _apiService.getCircleMembers(_currentCircle!.id);

      // 合并更新：保留运行时已获取的地址，不覆盖
      final existingMap = {for (var m in _members) m['id'] as String: m};

      for (final m in members) {
        final id = m['id'] as String;
        final existing = existingMap[id];

        // 如果服务器返回的 address 为空，但本地已有地址，保留本地地址
        if (existing != null) {
          final serverAddr = m['address'] as String?;
          final localAddr = existing['address'] as String?;
          if ((serverAddr == null || serverAddr.isEmpty) && localAddr != null && localAddr.isNotEmpty) {
            m['address'] = localAddr;
          }
        }

        // 如果是自己且有缓存的 _myAddress，优先使用
        if (id == widget.currentUser.id && _myAddress.isNotEmpty) {
          m['address'] = _myAddress;
        }
      }

      setState(() => _members = members);

      // 为地址为空的成员主动触发逆地理解码
      for (final m in members) {
        final addr = m['address'] as String?;
        debugPrint('[Members] ${m['name']}: address="$addr", lat=${m['latitude']}, lng=${m['longitude']}');
        if ((addr == null || addr.isEmpty) && m['latitude'] != null && m['longitude'] != null) {
          debugPrint('[Members]   → 为 ${m['name']} 主动获取逆地理地址');
          _fetchMemberAddress(m);
        }
      }

      for (final m in members) {
        if (m['latitude'] != null && m['longitude'] != null) {
          final id = m['id'] as String;
          final gcjPos = _wgs84ToGcj02(
            (m['latitude'] as num).toDouble(),
            (m['longitude'] as num).toDouble(),
          );
          if (!_memberTrails.containsKey(id)) {
            _memberTrails[id] = MemberTrail(
              userId: id,
              name: m['name'] ?? '未知',
              color: _parseColor(m['avatar_color'] ?? '#64748B'),
              currentPos: gcjPos,
            );
          }
          if (m['speed'] != null) {
            _memberTrails[id]!.speed = (m['speed'] as num).toDouble();
          }
        }
      }
    } catch (e) {
      debugPrint('加载成员失败: $e');
    }
  }

  /// 为单个成员获取逆地理地址
  Future<void> _fetchMemberAddress(Map<String, dynamic> member) async {
    try {
      final lat = (member['latitude'] as num).toDouble();
      final lng = (member['longitude'] as num).toDouble();
      debugPrint('[FetchAddr] 为成员 ${member['name']} 获取地址: lat=$lat, lng=$lng');
      final result = await _apiService.reverseGeocode(lat, lng);
      // 优先用完整 address，formatted 只有街道名
      final addr = (result['address'] as String?)?.isNotEmpty == true
          ? result['address'] as String
          : (result['formatted'] as String? ?? '');
      debugPrint('[FetchAddr] 成员 ${member['name']} 地址结果: "$addr"');
      if (addr.isNotEmpty && mounted) {
        setState(() {
          final idx = _members.indexWhere((m) => m['id'] == member['id']);
          if (idx >= 0) _members[idx]['address'] = addr;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadGeofences() async {
    if (_currentCircle == null) return;
    try {
      final fences = await _apiService.getGeofences(_currentCircle!.id);
      setState(() => _geofences = fences);
    } catch (_) {}
  }

  // ==================== SOS ====================

  Future<void> _sendSos() async {
    if (_currentPosition == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [Icon(Icons.warning, color: Colors.red), SizedBox(width: 8), Text('紧急求助')]),
        content: const Text('将向所有圈子成员发送你的位置和求助通知，确认？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('确认发送'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    _vibrate();
    try {
      await _apiService.sendSos(
        widget.currentUser.id,
        _currentPosition!.latitude,
        _currentPosition!.longitude,
      );
      if (mounted) {
        _showNotification('SOS 已发送！所有成员将会收到通知', icon: Icons.check_circle, color: Colors.red);
      }
    } catch (e) {
      if (mounted) {
        _showNotification('SOS 发送失败: $e', icon: Icons.error, color: Colors.red);
      }
    }
  }

  /// 二.4 碰撞检测 - 拨打紧急联系人电话
  Future<void> _callEmergencyContact() async {
    try {
      // 查找紧急联系人
      final contacts = await _apiService.getEmergencyContacts(widget.currentUser.id);
      if (contacts.isEmpty) {
        if (mounted) {
          _showNotification('未设置紧急联系人，请先在设置中添加', icon: Icons.person_off, color: Colors.orange);
        }
        return;
      }
      // 拨打第一个紧急联系人
      final phone = contacts[0]['phone'] as String?;
      if (phone != null && phone.isNotEmpty) {
        // 使用 url_launcher 拨号，这里用最简单的方式
        // 由于没引入 url_launcher，用 tel: scheme 提示用户
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('紧急联系'),
              content: Text('紧急联系人: ${contacts[0]['name'] ?? '未知'}\n电话: $phone'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Clipboard.setData(ClipboardData(text: phone));
                    _showNotification('已复制电话号码到剪贴板: $phone');
                  },
                  child: const Text('复制号码'),
                ),
              ],
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) _showNotification('获取紧急联系人失败: $e', icon: Icons.error, color: Colors.red);
    }
  }

  void _showSosDialog(SosAlert alert) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
            child: const Icon(Icons.warning, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 8),
          const Text('紧急求助！'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('来自: ${alert.userId}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            if (alert.address != null) ...[
              const SizedBox(height: 8),
              Text('位置: ${alert.address}'),
            ],
            Text('坐标: ${alert.latitude.toStringAsFixed(4)}, ${alert.longitude.toStringAsFixed(4)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _mapController.move(_wgs84ToGcj02(alert.latitude, alert.longitude), 16);
            },
            child: const Text('查看位置'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 1.5 碰撞检测全屏红色警告卡片
  void _showCollisionAlert(Map<String, dynamic> data) {
    final type = data['type'] as String? ?? 'high_speed';
    final title = type == 'hard_brake' ? '紧急刹车警报！' : '高速行驶警报！';
    final desc = type == 'hard_brake'
        ? '${data['userName']} 可能发生了急刹车！(从${((data['prevSpeed'] as num?) ?? 0) * 3.6}km/h骤降)'
        : '${data['userName']} 速度异常 (${((data['speed'] as num?) ?? 0) * 3.6}km/h)';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.red.shade50,
        title: Row(children: [
          const Icon(Icons.car_crash, color: Colors.red, size: 28),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(color: Colors.red)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(desc, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            const Text('可能发生了碰撞事故，请立即确认对方安全！'),
          ],
        ),
        actions: [
          // 二.4 拨打紧急电话
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _callEmergencyContact();
            },
            icon: const Icon(Icons.phone, color: Colors.red),
            label: const Text('紧急电话', style: TextStyle(color: Colors.red)),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              if (data['latitude'] != null && data['longitude'] != null) {
                _mapController.move(
                  _wgs84ToGcj02(
                    (data['latitude'] as num).toDouble(),
                    (data['longitude'] as num).toDouble(),
                  ), 16,
                );
              }
            },
            icon: const Icon(Icons.my_location, color: Colors.red),
            label: const Text('查看位置', style: TextStyle(color: Colors.red)),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _socketService.sendThinkingOfYou(
                userId: widget.currentUser.id,
                userName: widget.currentUser.name,
              );
            },
            icon: const Icon(Icons.favorite, color: Colors.red),
            label: const Text('发送关怀', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('我已知晓'),
          ),
        ],
      ),
    );
  }

  // ==================== 表情炸弹 ====================

  void _triggerEmojiBomb(String emoji, int count) {
    setState(() {
      for (int i = 0; i < count; i++) {
        _emojiParticles.add(_EmojiParticle(
          emoji: emoji,
          x: 100 + (i % 5) * 60.0,
          y: 300.0 + (i / 5).floor() * 60.0,
          vy: -2.0 - (i % 3),
          opacity: 1.0,
        ));
      }
    });
    // 渐隐动画
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (mounted) setState(() => _emojiParticles.clear());
    });
  }

  // ==================== 辅助方法 ====================

  void _showNotification(String text, {IconData icon = Icons.info, Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ]),
        duration: const Duration(seconds: 3),
        backgroundColor: color ?? const Color(0xFF334155),
      ),
    );
  }

  Future<void> _vibrate() async {
    try { await HapticFeedback.heavyImpact(); } catch (_) {}
  }

  // ==================== UI 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildHeader(),
                Expanded(child: _buildMap()),
                _buildBottomPanel(),
              ],
            ),
            // GPS调试浮窗
            if (_gpsDebugEnabled) _buildGpsDebugOverlay(),
            // 模拟驾驶浮窗
            if (_simMode) _buildSimOverlay(),
          ],
        ),
      ),
      // SOS 浮动按钮
      floatingActionButton: _currentCircle != null
          ? SizedBox(
              width: 56,
              height: 56,
              child: FloatingActionButton(
                onPressed: _sendSos,
                backgroundColor: Colors.red,
                child: const Icon(Icons.sos, color: Colors.white, size: 28),
              ),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _isDark ? const Color(0xFF1E293B) : Colors.white,
        border: Border(bottom: BorderSide(color: _isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _currentCircle?.name ?? 'FamilyMap',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: _isDark ? Colors.white : Colors.black87,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 聊天
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline, size: 20),
            onPressed: _currentCircle != null ? () => _openChat() : null,
            tooltip: '群聊',
          ),
          // 定位自己
          IconButton(
            icon: const Icon(Icons.my_location, size: 20),
            onPressed: _locateMe,
            tooltip: '定位自己',
          ),
          // 设置
          IconButton(
            icon: const Icon(Icons.settings, size: 20),
            onPressed: _openSettings,
            tooltip: '设置',
          ),
          // 圈子管理
          IconButton(
            icon: const Icon(Icons.group_add, size: 20),
            onPressed: _showCircleManager,
            tooltip: '圈子管理',
          ),
        ],
      ),
    );
  }

  Widget _buildMap() {
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: LatLng(39.9042, 116.4074),
            initialZoom: 13,
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
            // 长按地图选点创建围栏
            onLongPress: (position, point) {
              if (_isPlacingGeofence) return; // 防止重复触发
              setState(() {
                _geofencePinPos = point; // GCJ-02坐标（因为地图用的就是GCJ-02）
                _isPlacingGeofence = true;
              });
              _showGeofenceCreateDialog(point);
            },
          ),
          children: [
            TileLayer(
              // 1.6 深色模式适配：高德暗色瓦片需要用wprd域名(style=7)
              urlTemplate: widget.darkMode || _userSettings?.darkMode == true
                  ? 'https://wprd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=2&style=7&x={x}&y={y}&z={z}'
                  : 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=2&style=8&x={x}&y={y}&z={z}',
              subdomains: const ['1', '2', '3', '4'],
              maxZoom: 18,
            ),
            // 4.5 热力图层 - 用渐变色圆点表示停留密度
            if (_showHeatmap && _heatmapPoints.isNotEmpty)
              CircleLayer(
                circles: _heatmapPoints.map((p) {
                  final intensity = (p['intensity'] as num).toDouble();
                  // 颜色：低强度蓝绿→高强度红
                  final color = Color.lerp(
                    const Color(0xFF00BCD4), // 青色
                    const Color(0xFFFF1744), // 红色
                    intensity,
                  )!.withOpacity(0.3 + intensity * 0.4);
                  return CircleMarker(
                    point: LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
                    radius: 50 + intensity * 100, // 50-150米半径
                    useRadiusInMeter: true,
                    color: color,
                    borderColor: Colors.transparent,
                    borderStrokeWidth: 0,
                  );
                }).toList(),
              ),
            // 围栏层（useRadiusInMeter=true 让围栏按米为单位，随地图缩放正确变化）
            // 围栏坐标存储为WGS-84，渲染时转GCJ-02以匹配地图
            CircleLayer(
              circles: _geofences.map((f) => CircleMarker(
                point: _wgs84ToGcj02(f.latitude, f.longitude),
                radius: f.radius.toDouble(),
                useRadiusInMeter: true,
                color: Colors.orange.withOpacity(0.15),
                borderColor: Colors.orange,
                borderStrokeWidth: 2,
              )).toList(),
            ),
            // 二.3 幽灵模式-模糊位置虚化圆圈（500米半径的紫色虚化区域）
            CircleLayer(
              circles: _members
                .where((m) => m['ghost_mode'] == 'blur' && m['latitude'] != null)
                .map((m) => CircleMarker(
                  point: _wgs84ToGcj02(
                    (m['latitude'] as num).toDouble(),
                    (m['longitude'] as num).toDouble(),
                  ),
                  radius: 250, // 500米直径
                  useRadiusInMeter: true,
                  color: const Color(0xFF6366F1).withOpacity(0.12),
                  borderColor: const Color(0xFF6366F1).withOpacity(0.4),
                  borderStrokeWidth: 1.5,
                )).toList(),
            ),
            // 围栏选点标记（长按地图选择的位置）
            if (_geofencePinPos != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: _geofencePinPos!,
                    width: 40,
                    height: 40,
                    child: const Icon(Icons.location_pin, color: Colors.orange, size: 40),
                  ),
                ],
              ),
            // 成员标记 - 同位置花瓣状排列
            MarkerLayer(
              markers: _buildClusteredMarkers(),
            ),
          ],
        ),
        // 拖尾粒子层
        Positioned.fill(
          child: IgnorePointer(
            child: TrailParticleLayer(
              mapController: _mapController,
              memberTrails: _memberTrails,
            ),
          ),
        ),
        // 表情炸弹层
        if (_emojiParticles.isNotEmpty)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _EmojiBombPainter(_emojiParticles),
                size: Size.infinite,
              ),
            ),
          ),
        // 缩放控件
        Positioned(
          right: 8,
          top: 8,
          child: Column(
            children: [
              _zoomButton(Icons.add, () => _mapController.move(_mapController.camera.center, _mapController.camera.zoom + 1)),
              const SizedBox(height: 4),
              _zoomButton(Icons.remove, () => _mapController.move(_mapController.camera.center, _mapController.camera.zoom - 1)),
              const SizedBox(height: 8),
              // 4.5 热力图切换按钮
              _zoomButton(
                _showHeatmap ? Icons.layers_clear : Icons.layers,
                _toggleHeatmap,
                color: _showHeatmap ? Colors.blue : null,
              ),
              const SizedBox(height: 8),
              // 模拟驾驶切换按钮
              _zoomButton(
                Icons.directions_car,
                () {
                  if (_simMode) {
                    _stopSimMode();
                  } else {
                    _startSimMode();
                  }
                },
                color: _simMode ? Colors.orange : null,
              ),
            ],
          ),
        ),
        // 暂停共享标记
        if (_userSettings?.sharePaused == true)
          Positioned(
            left: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.orange.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange),
              ),
              child: const Row(children: [
                Icon(Icons.pause_circle, color: Colors.orange, size: 16),
                SizedBox(width: 4),
                Text('位置暂停共享', style: TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.w500)),
              ]),
            ),
          ),
      ],
    );
  }

  Widget _zoomButton(IconData icon, VoidCallback onPressed, {Color? color}) {
    return Container(
      decoration: BoxDecoration(
        color: color ?? Colors.white,
        borderRadius: BorderRadius.circular(4),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: IconButton(
        icon: Icon(icon, size: 18, color: color != null ? Colors.white : null),
        onPressed: onPressed,
        padding: const EdgeInsets.all(4),
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      ),
    );
  }

  // ==================== 可拖动底部面板 ====================

  Widget _buildBottomPanel() {
    return GestureDetector(
      onVerticalDragStart: (details) {
        _dragStartY = details.globalPosition.dy;
        _dragStartHeight = _panelHeight;
      },
      onVerticalDragUpdate: (details) {
        final dy = _dragStartY - details.globalPosition.dy;
        setState(() {
          _panelHeight = (_dragStartHeight + dy).clamp(_panelPeek, _panelFull);
        });
      },
      onVerticalDragEnd: (_) {
        // 松手时吸附到最近档位
        _snapPanel();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutBack, // 弹性缓动
        height: _panelHeight,
        decoration: BoxDecoration(
          color: widget.darkMode || _userSettings?.darkMode == true
              ? const Color(0xFF1E293B)
              : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: const [
            BoxShadow(color: Color(0x18000000), blurRadius: 30, offset: Offset(0, -8)),
          ],
        ),
        child: Column(
          children: [
            // 拖拽把手
            GestureDetector(
              onTap: () {
                // 点击把手在 peek ↔ half ↔ full 之间循环
                if (_panelHeight < (_panelPeek + _panelHalf) / 2) {
                  _animatePanelTo(_panelHalf);
                } else if (_panelHeight < (_panelHalf + _panelFull) / 2) {
                  _animatePanelTo(_panelFull);
                } else {
                  _animatePanelTo(_panelPeek);
                }
              },
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: widget.darkMode || _userSettings?.darkMode == true
                      ? const Color(0xFF475569)
                      : const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Tab 栏
            Row(
              children: ['成员', '圈子', '围栏', '轨迹']
                  .asMap()
                  .entries
                  .map((e) => Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _currentTab = e.key),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: _currentTab == e.key
                                      ? const Color(0xFF4F46E5)
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                            ),
                            child: Text(
                              e.value,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: _currentTab == e.key
                                    ? const Color(0xFF4F46E5)
                                    : widget.darkMode || _userSettings?.darkMode == true
                                        ? const Color(0xFF94A3B8)
                                        : const Color(0xFF64748B),
                              ),
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
            // 内容
            Expanded(child: _buildTabContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildTabContent() {
    switch (_currentTab) {
      case 0: return KeyedSubtree(key: const ValueKey('members'), child: _buildMembersList());
      case 1: return KeyedSubtree(key: const ValueKey('circles'), child: _buildCirclesList());
      case 2: return KeyedSubtree(key: const ValueKey('fences'), child: _buildFencesList());
      case 3: return KeyedSubtree(key: const ValueKey('history'), child: _buildHistoryTab());
      default: return const SizedBox.shrink();
    }
  }

  // ==================== 成员列表（含地址和停留时长） ====================

  Widget _buildMembersList() {
    if (_members.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.group, size: 32, color: Color(0xFFCBD5E1)),
            const SizedBox(height: 8),
            const Text('还没有成员', style: TextStyle(color: Color(0xFF64748B))),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _showCircleManager, child: const Text('邀请加入')),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: List.generate(_members.length, (i) {
        final m = _members[i];
        final id = m['id'] as String;
        final name = m['name'] as String;
        final isMe = id == widget.currentUser.id;
        final trail = _memberTrails[id];
        final color = _parseColor(m['avatar_color'] ?? '#4F46E5');
        final battery = m['battery_level'] as int?;
        final charging = (m['is_charging'] ?? 0) == 1;
        final lastTime = trail?.lastUpdate;
        final address = m['address'] as String?;
        final stayAddress = m['stay_address'] as String?;
        final stayMinutesRaw = m['stay_minutes'] as int?;
        final stayStartedAt = m['stay_started_at'] as String?;
        // 优先用 stay_started_at 实时计算停留时长
        int? stayMinutes;
        if (stayStartedAt != null) {
          final started = DateTime.tryParse(stayStartedAt);
          if (started != null) {
            stayMinutes = DateTime.now().difference(started).inMinutes;
          }
        }
        stayMinutes ??= stayMinutesRaw;
        final mood = m['mood'] as String?;
        final isSleeping = (m['is_sleeping'] ?? 0) == 1;
        final nicknameColor = m['nickname_color'] as String?;

        // 对标 Demo：交错入场 + 选中弹性反馈的卡片
        return _AnimatedMemberCard(
          key: ValueKey(id),
          index: i,
          isDark: _isDark,
          isSelected: _selectedMemberId == id,
          onTap: () {
            setState(() => _selectedMemberId = id);
            if (trail != null) {
              _mapController.move(trail.currentPos, 16);
            }
          },
          child: _buildMemberCardContent(
            name: name, isMe: isMe, color: color, mood: mood,
            isSleeping: isSleeping, nicknameColor: nicknameColor,
            ghostMode: m['ghost_mode'] as String?,
            trail: trail, battery: battery, charging: charging,
            lastTime: lastTime, address: address,
            stayAddress: stayAddress, stayMinutes: stayMinutes,
          ),
        );
      }),
      ),
    );
  }

  /// 选中的成员ID（用于高亮边框）
  String? _selectedMemberId;

  /// 构建成员卡片内容（抽出为独立方法以便复用）
  Widget _buildMemberCardContent({
    required String name, required bool isMe, required Color color,
    String? mood, bool isSleeping = false, String? nicknameColor,
    String? ghostMode,
    MemberTrail? trail, int? battery, bool charging = false,
    DateTime? lastTime, String? address,
    String? stayAddress, int? stayMinutes,
  }) {
    // 不用 ListTile（subtitle Column 会溢出），改用手动 Row 布局
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ---- 头像 ----
          Stack(
            children: [
              CircleAvatar(
                backgroundColor: color,
                child: Text(name[0].toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
              if (isSleeping)
                Positioned(right: 0, bottom: 0, child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(color: Colors.indigo, shape: BoxShape.circle),
                  child: const Icon(Icons.bedtime, size: 10, color: Colors.white),
                )),
            ],
          ),
          const SizedBox(width: 12),
          // ---- 中间信息（Expanded 防溢出）----
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 名字行
                Row(
                  children: [
                    Flexible(child: Text(name + (isMe ? '（我）' : ''),
                      style: TextStyle(
                        color: nicknameColor != null && nicknameColor.isNotEmpty ? _parseColor(nicknameColor) : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    )),
                    // 幽灵模式标签
                    if (ghostMode == 'invisible') ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade600,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('已隐身', style: TextStyle(fontSize: 10, color: Colors.white70)),
                      ),
                    ] else if (ghostMode == 'blur') ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6366F1).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('模糊位置', style: TextStyle(fontSize: 10, color: Color(0xFF6366F1))),
                      ),
                    ],
                    // 心情标签
                    if (mood != null && mood!.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: _isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(mood!, style: TextStyle(fontSize: 10, color: _isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B))),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                // 状态行：移动/静止 + 电量 + 时间
                Row(
                  children: [
                    Icon(
                      trail?.isMoving == true ? Icons.navigation : Icons.circle,
                      size: 10,
                      color: trail?.isMoving == true ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      trail?.isMoving == true ? '移动中' : (isSleeping ? '睡觉中' : '静止'),
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (battery != null) ...[
                      const SizedBox(width: 8),
                      _buildBatteryIndicator(battery, charging),
                    ],
                    if (lastTime != null) ...[
                      const SizedBox(width: 8),
                      Text(_formatTime(lastTime), style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
                    ],
                  ],
                ),
                // 地址：静止时优先停留地址（带时长），移动时显示实时地址
                if (trail?.isMoving != true && stayAddress != null && stayAddress.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const Icon(Icons.location_on, size: 11, color: Color(0xFF94A3B8)),
                      const SizedBox(width: 2),
                      Expanded(child: Text(
                        stayAddress,
                        style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )),
                    ],
                  ),
                  if (stayMinutes != null && stayMinutes > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 13),
                      child: Text(
                        _formatDuration(stayMinutes),
                        style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
                      ),
                    ),
                ] else if (address != null && address.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const Icon(Icons.location_on, size: 11, color: Color(0xFF94A3B8)),
                      const SizedBox(width: 2),
                      Expanded(child: Text(
                        address,
                        style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // ---- 右侧速度 ----
          if (trail != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                '${(trail.speed * 3.6).toStringAsFixed(0)} km/h',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF4F46E5)),
              ),
            ),
        ],
      ),
    );
  }

  /// 电量指示器（对标 Demo 的充电动画 + 低电量警告）
  Widget _buildBatteryIndicator(int level, bool charging) {
    final color = level > 50
        ? const Color(0xFF34C759)
        : level > 20
            ? const Color(0xFFFFC107)
            : const Color(0xFFFF6B6B);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (charging)
          const Icon(Icons.bolt, size: 12, color: Color(0xFF34C759)),
        if (!charging)
          const Icon(Icons.battery_std, size: 12, color: Color(0xFF94A3B8)),
        const SizedBox(width: 2),
        Text(
          '$level%',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
        if (level < 15 && !charging) ...[
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFFFF6B6B),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.warning, size: 8, color: Colors.white),
                SizedBox(width: 2),
                Text('低电量', style: TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ==================== 圈子列表 ====================

  Widget _buildCirclesList() {
    if (_circles.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.home, size: 32, color: Color(0xFFCBD5E1)),
            const SizedBox(height: 8),
            const Text('你还没有圈子', style: TextStyle(color: Color(0xFF64748B))),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _showCircleManager, child: const Text('创建圈子')),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: _circles.map((c) {
          final active = _currentCircle?.id == c.id;
          return Card(
            color: active
                ? (_isDark ? const Color(0xFF312E81) : const Color(0xFFEEF2FF))
                : null,
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xFF4F46E5),
                child: Icon(Icons.home, color: Colors.white),
              ),
              title: Text(c.name),
              subtitle: Text('${c.memberCount} 位成员'),
              trailing: Chip(
                label: Text(c.inviteCode, style: const TextStyle(fontSize: 11)),
                backgroundColor: _isDark ? const Color(0xFF334155) : const Color(0xFFEEF2FF),
              ),
              onTap: () => _selectCircle(c),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ==================== 围栏列表 ====================

  Widget _buildFencesList() {
    if (_geofences.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.fence, size: 32, color: Color(0xFFCBD5E1)),
            const SizedBox(height: 8),
            const Text('还没有围栏', style: TextStyle(color: Color(0xFF64748B))),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _currentCircle != null ? _createGeofence : null,
              child: const Text('创建围栏'),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: _geofences.map((f) {
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Colors.orange,
                child: Icon(Icons.fence, color: Colors.white, size: 18),
              ),
              title: Text(f.name),
              subtitle: Text('半径 ${f.radius}m'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: Color(0xFFEF4444)),
                onPressed: () => _deleteGeofence(f.id!),
              ),
              onTap: () => _mapController.move(_wgs84ToGcj02(f.latitude, f.longitude), 15),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ==================== 轨迹/历史 Tab ====================

  Widget _buildHistoryTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // 时间线入口
          Card(
            child: ListTile(
              leading: const CircleAvatar(backgroundColor: Color(0xFF4F46E5), child: Icon(Icons.timeline, color: Colors.white, size: 18)),
              title: const Text('行程时间线'),
              subtitle: const Text('查看今天的行程记录'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => TimelineScreen(currentUser: widget.currentUser, apiService: _apiService),
              )),
            ),
          ),
          const SizedBox(height: 8),
          // 足迹入口
          Card(
            child: ListTile(
              leading: const CircleAvatar(backgroundColor: Color(0xFF10B981), child: Icon(Icons.explore, color: Colors.white, size: 18)),
              title: const Text('我的足迹'),
              subtitle: const Text('管理保存的地点'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => FootprintScreen(currentUser: widget.currentUser, apiService: _apiService),
              )),
            ),
          ),
          const SizedBox(height: 8),
          // 世界迷雾
          Card(
            child: ListTile(
              leading: const CircleAvatar(backgroundColor: Color(0xFF8B5CF6), child: Icon(Icons.public, color: Colors.white, size: 18)),
              title: const Text('世界迷雾'),
              subtitle: const Text('查看你去过的地方'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showWorldStats,
            ),
          ),
          const SizedBox(height: 8),
          // 4.9 驾驶行为评分
          Card(
            child: ListTile(
              leading: const CircleAvatar(backgroundColor: Color(0xFFEF4444), child: Icon(Icons.speed, color: Colors.white, size: 18)),
              title: const Text('驾驶评分'),
              subtitle: const Text('查看近7天驾驶行为评估'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showDrivingScore,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 导航 ====================

  void _openChat() {
    if (_currentCircle == null) return;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => ChatScreen(
        circle: _currentCircle!,
        currentUser: widget.currentUser,
        socketService: _socketService,
        apiService: _apiService,
      ),
    ));
  }

  void _openSettings() {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SettingsScreen(
        currentUser: widget.currentUser,
        apiService: _apiService,
        darkMode: widget.darkMode,
        onDarkModeChanged: widget.onDarkModeChanged,
      ),
    )).then((result) {
      _loadSettings();
      _loadGpsDebugFlag();
    });
  }

  void _locateMe() {
    if (_currentPosition != null) {
      _mapController.move(
        _wgs84ToGcj02(_currentPosition!.latitude, _currentPosition!.longitude), 15,
      );
    } else {
      _initLocation();
    }
  }

  // ==================== Jagat 风格层叠标记排列 ====================

  /// 同位置成员层叠排列（Jagat 风格）
  /// 自己在最上层居中，其他成员往右上偏移
  /// 所有底部尖角指向同一个坐标点
  List<Marker> _buildClusteredMarkers() {
    final trails = _memberTrails.values.toList();
    if (trails.isEmpty) return [];

    // 判定为"同一位置"的距离阈值（约 50 米）
    const clusterThreshold = 0.0005;
    // 层叠偏移距离（经纬度，约10米，只露出一点边缘）
    const stackOffset = 0.00012;

    // 1. 按位置分组
    final List<List<int>> groups = [];
    final List<bool> assigned = List.filled(trails.length, false);

    for (int i = 0; i < trails.length; i++) {
      if (assigned[i]) continue;
      final group = <int>[i];
      assigned[i] = true;
      for (int j = i + 1; j < trails.length; j++) {
        if (assigned[j]) continue;
        final dist = _latLngDistance(trails[i].currentPos, trails[j].currentPos);
        if (dist < clusterThreshold) {
          group.add(j);
          assigned[j] = true;
        }
      }
      groups.add(group);
    }

    // 2. 对同位置组：自己居中，其他人往右上方依次偏移
    final Map<String, LatLng> adjustedPositions = {};

    for (final group in groups) {
      if (group.length == 1) {
        adjustedPositions[trails[group[0]].userId] = trails[group[0]].currentPos;
      } else {
        // 先找自己是否在这一组中
        final myIndex = group.indexWhere((i) => trails[i].userId == widget.currentUser.id);
        // 中心点：优先用自己的位置，否则用第一个成员
        final centerIdx = myIndex >= 0 ? group[myIndex] : group[0];
        final centerPos = trails[centerIdx].currentPos;

        // 自己放在中心（不上层，由 Marker 叠放顺序决定层级）
        for (int idx = 0; idx < group.length; idx++) {
          final trailIdx = group[idx];
          final trail = trails[trailIdx];
          if (trailIdx == centerIdx) {
            // 中心位置
            adjustedPositions[trail.userId] = centerPos;
          } else {
            // 偏移到右上（约30-45度），每多一人再往右偏一点
            final offsetCount = idx > (myIndex >= 0 ? myIndex : 0) ? idx : idx + 1;
            final offsetLat = centerPos.latitude + stackOffset * offsetCount * 0.5;
            final offsetLng = centerPos.longitude + stackOffset * offsetCount;
            adjustedPositions[trail.userId] = LatLng(offsetLat, offsetLng);
          }
        }
      }
    }

    // 3. 生成 Marker 列表
    // 关键：自己要最后添加（Flutter MarkerLayer 后添加的在上层）
    // 先排非自己，再排自己 → 自己在最上层
    final sortedTrails = List<MemberTrail>.from(trails)..sort((a, b) {
      final aIsMe = a.userId == widget.currentUser.id ? 1 : 0;
      final bIsMe = b.userId == widget.currentUser.id ? 1 : 0;
      return aIsMe - bIsMe; // 自己排最后（最上层）
    });

    int markerIndex = 0;
    return sortedTrails.map((trail) {
      final isMe = trail.userId == widget.currentUser.id;
      final member = _members.firstWhere(
        (m) => m['id'] == trail.userId, orElse: () => {},
      );
      final isOnline = _onlineMembers.contains(trail.userId);
      final pos = adjustedPositions[trail.userId] ?? trail.currentPos;
      return Marker(
        point: pos,
        width: 80,
        height: 110,
        child: MemberMarker(
          name: trail.name,
          color: trail.color,
          isMe: isMe,
          isOnline: isOnline,
          isMoving: trail.isMoving,
          heading: trail.heading,
          movementType: trail.movementType,
          batteryLevel: member['battery_level'] as int?,
          isCharging: (member['is_charging'] ?? 0) == 1,
          onTap: () => _showMemberDetail(trail, member),
          index: markerIndex++,
        ),
      );
    }).toList();
  }

  /// 简易经纬度距离（返回差值绝对值，用于判断是否在同一位置）
  double _latLngDistance(LatLng a, LatLng b) {
    final dLat = (a.latitude - b.latitude).abs();
    final dLng = (a.longitude - b.longitude).abs();
    return sqrt(dLat * dLat + dLng * dLng);
  }

  // ==================== 成员详情弹窗 ====================

  void _showMemberDetail(MemberTrail trail, Map<String, dynamic> member) {
    final address = member['address'] as String?;
    final stayAddress = member['stay_address'] as String?;
    final stayMinutesRaw = member['stay_minutes'] as int?;
    final stayStartedAt = member['stay_started_at'] as String?;
    // 优先用 stay_started_at 实时计算停留时长
    int? stayMinutes;
    if (stayStartedAt != null) {
      final started = DateTime.tryParse(stayStartedAt);
      if (started != null) {
        stayMinutes = DateTime.now().difference(started).inMinutes;
      }
    }
    stayMinutes ??= stayMinutesRaw;
    final mood = member['mood'] as String?;
    final isSleeping = (member['is_sleeping'] ?? 0) == 1;
    final speedKmh = (trail.speed * 3.6).toStringAsFixed(0);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头像和名字
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: trail.color,
                  child: Text(trail.name[0].toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(trail.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                      if (mood != null && mood!.isNotEmpty)
                        Text(mood!, style: const TextStyle(color: Color(0xFF64748B))),
                    ],
                  ),
                ),
                if (isSleeping) const Icon(Icons.bedtime, color: Colors.indigo, size: 28),
              ],
            ),
            const SizedBox(height: 16),
            
            // 状态信息
            _detailRow(
              trail.isMoving ? Icons.navigation : Icons.circle,
              trail.isMoving ? '移动中 $speedKmh km/h' : (isSleeping ? '睡觉中' : '静止'),
              trail.isMoving ? Colors.green : Colors.grey,
            ),
            
            // 地址显示：静止时优先显示停留地址（带时长），移动中显示实时地址
            // 避免 stay_address 和 address 相同时重复显示
            if (!trail.isMoving && stayAddress != null && stayAddress.isNotEmpty)
              _detailRow(
                Icons.location_on,
                stayMinutes != null && stayMinutes > 0
                    ? '$stayAddress · ${_formatDuration(stayMinutes)}'
                    : stayAddress,
                const Color(0xFF64748B),
              )
            else if (address != null && address.isNotEmpty)
              _detailRow(Icons.place, address, const Color(0xFF94A3B8)),
            
            const SizedBox(height: 12),
            
            // 操作按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _mapController.move(trail.currentPos, 16);
                  },
                  icon: const Icon(Icons.my_location),
                  label: const Text('查看位置'),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _socketService.sendThinkingOfYou(
                      userId: widget.currentUser.id,
                      userName: widget.currentUser.name,
                    );
                  },
                  icon: const Icon(Icons.favorite),
                  label: const Text('想你'),
                ),
                // 4.1 预计到达时间(ETA)
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _showEta(trail);
                  },
                  icon: const Icon(Icons.access_time),
                  label: const Text('到达'),
                ),
              ],
            ),
            // 第二行按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // 4.2 分享位置链接给非用户
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _shareLocationLink(trail);
                  },
                  icon: const Icon(Icons.share),
                  label: const Text('分享链接'),
                ),
                // 4.7 行程分享给非用户（实时追踪）
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _shareTripLink(trail);
                  },
                  icon: const Icon(Icons.navigation),
                  label: const Text('行程分享'),
                ),
              ],
            ),
            // 第三行按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // 4.8 GPX轨迹导出
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _exportGpx(trail);
                  },
                  icon: const Icon(Icons.download),
                  label: const Text('导出轨迹'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 4.1 预计到达时间(ETA) ====================

  /// 计算并显示从自己的位置到目标成员的预计到达时间
  Future<void> _showEta(MemberTrail trail) async {
    if (_currentPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在获取您的位置，请稍后')),
      );
      return;
    }
    try {
      // 把自己的WGS-84坐标和服务端ETA API对接
      final result = await _apiService.getEta(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
        trail.currentPos.latitude,
        trail.currentPos.longitude,
        speed: _simMode ? _simSpeedMs : (_isCurrentlyMoving ? _getAverageSpeed() : 1.0), // 默认步行速度
      );
      if (!mounted) return;
      final distanceKm = (result['distanceKm'] as num).toStringAsFixed(1);
      final etaMin = result['etaMinutes'] as int;
      final etaText = etaMin >= 60
          ? '${etaMin ~/ 60}小时${etaMin % 60}分钟'
          : '$etaMin分钟';
      showModalBottomSheet(
        context: context,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('前往 ${trail.name}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Column(children: [
                    const Icon(Icons.straighten, size: 32, color: Color(0xFF4F46E5)),
                    const SizedBox(height: 4),
                    Text('$distanceKm km', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const Text('直线距离', style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                  ]),
                  Column(children: [
                    const Icon(Icons.access_time, size: 32, color: Color(0xFF10B981)),
                    const SizedBox(height: 4),
                    Text(etaText, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const Text('预计到达', style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                  ]),
                ],
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('计算到达时间失败: $e')),
        );
      }
    }
  }

  // ==================== 4.2 分享位置链接 ====================

  /// 生成临时分享链接，让非注册用户也能查看成员位置
  Future<void> _shareLocationLink(MemberTrail trail) async {
    try {
      final result = await _apiService.createShareLink(
        trail.userId,
        trail.currentPos.latitude,
        trail.currentPos.longitude,
        durationMinutes: 24 * 60, // 24小时有效
      );
      final url = result['url'] as String? ?? 'https://www.zhp0104.fun:8090/share/${result['token']}';
      // 复制到剪贴板
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已复制分享链接（24小时有效）: $url'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('生成分享链接失败: $e')),
        );
      }
    }
  }

  /// 4.7 行程分享给非用户 - 生成带实时追踪的分享链接
  Future<void> _shareTripLink(MemberTrail trail) async {
    try {
      final result = await _apiService.createShareLink(
        trail.userId,
        trail.currentPos.latitude,
        trail.currentPos.longitude,
        durationMinutes: 4 * 60, // 行程分享4小时有效
        trackMode: true, // 行程模式：对方能看到实时移动位置
      );
      final url = result['url'] as String? ?? 'https://www.zhp0104.fun:8090/share/${result['token']}';
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已复制行程分享链接（4小时实时追踪）: $url'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('生成行程分享链接失败: $e')),
        );
      }
    }
  }

  // ==================== 4.8 GPX轨迹导出 ====================

  /// 导出成员某天的GPS轨迹为GPX文件
  Future<void> _exportGpx(MemberTrail trail) async {
    final today = DateTime.now();
    final dateStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final url = _apiService.getGpxExportUrl(trail.userId, date: dateStr);
    // 复制GPX下载链接到剪贴板
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已复制GPX下载链接: $url'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Widget _detailRow(IconData icon, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 14, color: color))),
        ],
      ),
    );
  }

  // ==================== 圈子管理弹窗 ====================

  void _showCircleManager() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('圈子管理', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _createCircle(ctx),
              icon: const Icon(Icons.add),
              label: const Text('创建新圈子'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _joinCircle(ctx),
              icon: const Icon(Icons.login),
              label: const Text('加入圈子'),
            ),
            const SizedBox(height: 16),
            ..._circles.map((c) => Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Color(0xFF4F46E5),
                      child: Icon(Icons.home, color: Colors.white, size: 18),
                    ),
                    title: Text(c.name),
                    subtitle: Text('邀请码: ${c.inviteCode}'),
                    trailing: TextButton(
                      onPressed: () { Navigator.pop(ctx); _selectCircle(c); },
                      child: const Text('进入'),
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  // ==================== 围栏操作 ====================

  /// 长按地图后弹出围栏创建对话框（位置已确定）
  void _showGeofenceCreateDialog(LatLng gcjPos) {
    final nameCtrl = TextEditingController();
    final radiusCtrl = TextEditingController(text: '200');

    // GCJ-02 坐标需要转回 WGS-84 存入数据库（地图上的GCJ-02 → 真实WGS-84）
    // 近似逆转换：减去典型偏移量（中国境内偏移量约0.004-0.006度）
    // 更精确的做法是做完整的逆转换，但这里精度足够
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('在此创建围栏'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('位置: ${gcjPos.latitude.toStringAsFixed(5)}, ${gcjPos.longitude.toStringAsFixed(5)}',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '围栏名称', hintText: '如：家、公司、学校'), autofocus: true),
            const SizedBox(height: 8),
            TextField(controller: radiusCtrl, decoration: const InputDecoration(labelText: '半径(米)', hintText: '200'), keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            const Text('提示: 长按地图任意位置即可选点创建围栏', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(onPressed: () {
            setState(() { _geofencePinPos = null; _isPlacingGeofence = false; });
            Navigator.pop(ctx);
          }, child: const Text('取消')),
          TextButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty || _currentCircle == null) return;
              Navigator.pop(ctx);
              try {
                final wgs = _gcj02ToWgs84(gcjPos.latitude, gcjPos.longitude);
                await _apiService.createGeofence(
                  _currentCircle!.id,
                  nameCtrl.text.trim(),
                  wgs.latitude,  // 存WGS-84，服务器端距离计算统一
                  wgs.longitude,
                  int.tryParse(radiusCtrl.text) ?? 200,
                  widget.currentUser.id,
                );
                setState(() { _geofencePinPos = null; _isPlacingGeofence = false; });
                _loadGeofences();
              } catch (e) {
                if (mounted) _showNotification('创建围栏失败: $e', icon: Icons.error, color: Colors.red);
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  /// 从按钮创建围栏（使用当前位置，如果没有位置则提示长按地图选点）
  Future<void> _createGeofence() async {
    if (_currentCircle == null) return;

    if (_currentPosition == null) {
      _showNotification('请长按地图选择围栏位置', icon: Icons.info, color: Colors.orange);
      return;
    }

    final gcjPos = _wgs84ToGcj02(_currentPosition!.latitude, _currentPosition!.longitude);
    setState(() { _geofencePinPos = gcjPos; _isPlacingGeofence = true; });
    _showGeofenceCreateDialog(gcjPos);
  }

  Future<void> _deleteGeofence(int id) async {
    try {
      await _apiService.deleteGeofence(id);
      _loadGeofences();
    } catch (_) {}
  }

  // ==================== 世界迷雾 ====================

  Future<void> _showWorldStats() async {
    try {
      final stats = await _apiService.getWorldStats(widget.currentUser.id);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(children: [Icon(Icons.public, color: Color(0xFF8B5CF6)), SizedBox(width: 8), Text('世界迷雾')]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('探索区域: ${stats.gridCount} 个网格', style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 8),
              Text('去过 ${stats.cityCount} 个城市', style: const TextStyle(fontSize: 16)),
              if (stats.cities.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('城市列表:', style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: stats.cities.map((c) => Chip(label: Text(c, style: const TextStyle(fontSize: 12)))).toList(),
                ),
              ],
            ],
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
        ),
      );
    } catch (e) {
      if (mounted) _showNotification('获取数据失败: $e', icon: Icons.error, color: Colors.red);
    }
  }

  // ==================== 4.9 驾驶行为评分 ====================

  Future<void> _showDrivingScore() async {
    try {
      final data = await _apiService.getDrivingScore(widget.currentUser.id, days: 7);
      if (!mounted) return;
      final score = data['score'];
      if (score == null) {
        _showNotification(data['message'] ?? '数据不足');
        return;
      }
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(children: [Icon(Icons.speed, color: Color(0xFFEF4444)), SizedBox(width: 8), Text('驾驶评分')]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 大号评分
              Text(
                '${score}',
                style: TextStyle(
                  fontSize: 64,
                  fontWeight: FontWeight.bold,
                  color: _parseColor(data['gradeColor']),
                ),
              ),
              Text(
                '${data['grade']} 级',
                style: TextStyle(fontSize: 20, color: _parseColor(data['gradeColor'])),
              ),
              const Divider(height: 24),
              // 详细指标
              _scoreRow('平均速度', '${data['avgSpeedKmh']} km/h'),
              _scoreRow('最高速度', '${data['maxSpeedKmh']} km/h'),
              _scoreRow('超速次数', '${data['speedingCount']}'),
              _scoreRow('急刹次数', '${data['hardBrakeCount']}'),
              _scoreRow('高速行驶', '${data['highSpeedCount']} 次'),
              const SizedBox(height: 8),
              Text('近 ${data['days']} 天 · ${data['totalRecords']} 条记录',
                style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
            ],
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
        ),
      );
    } catch (e) {
      if (mounted) _showNotification('获取驾驶评分失败: $e', icon: Icons.error, color: Colors.red);
    }
  }

  Widget _scoreRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF64748B))),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Color _parseColor(String? hex) {
    if (hex == null) return Colors.blue;
    try {
      return Color(int.parse('FF${hex.substring(1)}', radix: 16));
    } catch (_) {
      return Colors.blue;
    }
  }

  // ==================== 圈子创建/加入 ====================

  Future<void> _createCircle(BuildContext ctx) async {
    final name = await showDialog<String>(
      context: ctx,
      builder: (ctx) {
        final ctrl = TextEditingController(text: '我的家人');
        return AlertDialog(
          title: const Text('创建圈子'),
          content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: '圈子名称'), autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('创建')),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;

    final circle = await _apiService.createCircle(name, widget.currentUser.id);
    if (mounted) {
      _showNotification('圈子已创建！邀请码: ${circle.inviteCode}');
    }
    await _loadCircles();
    _selectCircle(circle);
  }

  Future<void> _joinCircle(BuildContext ctx) async {
    final code = await showDialog<String>(
      context: ctx,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: const Text('加入圈子'),
          content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: '邀请码'), autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('加入')),
          ],
        );
      },
    );
    if (code == null || code.isEmpty) return;

    final result = await _apiService.joinCircle(code, widget.currentUser.id);
    if (mounted) {
      if (result['error'] != null) {
        _showNotification(result['error'].toString(), icon: Icons.error, color: Colors.red);
      } else {
        _showNotification(result['alreadyMember'] == true ? '你已经在圈子里了' : '加入成功！');
        await _loadCircles();
        _selectCircle(Circle.fromJson(result['circle']));
      }
    }
  }

  // ==================== 模拟驾驶模式 ====================

  /// 开启模拟模式
  void _startSimMode() {
    if (_simMode) return;
    _simMode = true;
    _gpsInitStatus = '模拟模式';
    _gpsStreamActive = false;
    // 暂停真实 GPS 流
    _positionStream?.cancel();
    _isLocationSharing = false;
    setState(() {});

    // 如果还没有当前位置，用地图中心
    if (_currentPosition == null) {
      final center = _mapController.camera.center;
      _currentPosition = Position(
        latitude: center.latitude,
        longitude: center.longitude,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
        isMocked: true,
      );
      // 初始化自己的 trail
      final myKey = widget.currentUser.id;
      if (!_memberTrails.containsKey(myKey)) {
        final gcjPos = _wgs84ToGcj02(center.latitude, center.longitude);
        _memberTrails[myKey] = MemberTrail(
          userId: myKey,
          name: widget.currentUser.name,
          color: _parseColor(widget.currentUser.avatarColor),
          currentPos: gcjPos,
        );
      }
    }

    // 启动模拟位置生成定时器（每500ms一个点）
    _simTimer?.cancel();
    _simTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!_simMoving) return; // 摇杆松开时不生成
      _generateSimPosition();
    });

    debugPrint('[模拟] 模拟驾驶模式已开启');
  }

  /// 关闭模拟模式，恢复真实GPS
  void _stopSimMode() {
    _simMode = false;
    _simTimer?.cancel();
    _simTimer = null;
    _simMoving = false;
    setState(() {});
    // 恢复真实 GPS
    _startLocationSharing();
    debugPrint('[模拟] 模拟驾驶模式已关闭，恢复GPS');
  }

  /// 模拟控制器回调
  void _onSimUpdate({required double bearing, required double speedMs, required bool isMoving}) {
    _simBearing = bearing;
    _simSpeedMs = speedMs;
    _simMoving = isMoving;
  }

  /// 生成一个模拟位置点并注入到管道
  void _generateSimPosition() {
    if (_currentPosition == null) return;

    final dt = 0.5; // 500ms 间隔
    final dist = _simSpeedMs * dt; // 移动距离（米）
    final bearingRad = _simBearing * pi / 180;

    // 根据方位角和距离计算新经纬度
    final lat = _currentPosition!.latitude;
    final lng = _currentPosition!.longitude;
    final deltaLat = dist * cos(bearingRad) / 111320.0;
    final deltaLng = dist * sin(bearingRad) / (111320.0 * cos(lat * pi / 180));

    final newPos = Position(
      latitude: lat + deltaLat,
      longitude: lng + deltaLng,
      timestamp: DateTime.now(),
      accuracy: 5.0, // 模拟信号精精度很高
      altitude: 0,
      altitudeAccuracy: 0,
      heading: _simBearing,
      headingAccuracy: 0,
      speed: _simSpeedMs,
      speedAccuracy: 0.5,
      isMocked: true,
    );

    // 地图跟随移动
    final gcjPos = _wgs84ToGcj02(newPos.latitude, newPos.longitude);
    _mapController.move(gcjPos, _mapController.camera.zoom);

    // 直接注入位置处理管道
    _handlePositionUpdate(newPos, forceUpdate: true);
  }

  /// 构建模拟控制浮窗
  Widget _buildSimOverlay() {
    return Positioned(
      left: 12,
      bottom: 170,
      child: SimControlPanel(
        onSimUpdate: _onSimUpdate,
        onStop: _stopSimMode,
      ),
    );
  }

  // ==================== 工具方法 ====================

  // _parseColor 已在上方定义（支持 String? 参数）

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    return '${diff.inDays}天前';
  }

  // ==================== GPS调试浮窗 ====================

  Widget _buildGpsDebugOverlay() {
    final logger = GpsDebugLogger.instance;
    final snap = logger.currentSnapshot;
    final curPos = _currentPosition;

    return Positioned(
      right: 12,
      bottom: 160,
      child: GestureDetector(
        onTap: () => _showGpsDebugDetail(),
        child: Container(
          width: 210,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: curPos != null ? const Color(0xFF10B981) : const Color(0xFFEF4444), width: 2),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 2))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题行
              Row(
                children: [
                  Container(
                    width: 8, height: 8,
                    decoration: BoxDecoration(
                      color: curPos != null ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text('GPS', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text(
                    curPos != null ? '已定位' : '未定位',
                    style: TextStyle(
                      color: curPos != null ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                      fontSize: 11, fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // 初始化状态（最重要的一行）
              _debugRow('状态', _gpsInitStatus, maxLen: 18),
              _debugRow('流', _gpsStreamActive ? '运行中' : '未启动'),
              // 如果有当前位置，直接显示（不依赖 GpsDebugLogger）
              if (curPos != null) ...[
                _debugRow('精度', '${curPos.accuracy.toStringAsFixed(1)}m'),
                _debugRow('速度', '${(curPos.speed * 3.6).toStringAsFixed(1)} km/h'),
                _debugRow('坐标', '${curPos.latitude.toStringAsFixed(5)}, ${curPos.longitude.toStringAsFixed(5)}'),
              ] else if (snap != null) ...[
                // 降级：用 logger 快照显示
                _debugRow('精度', '${snap.accuracy.toStringAsFixed(1)}m'),
                _debugRow('速度', '${(snap.speed * 3.6).toStringAsFixed(1)} km/h'),
              ],
              if (logger.enabled)
                Text('调试日志: ${logger.logs.length}条', style: const TextStyle(color: Color(0xFF64748B), fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _debugRow(String label, String value, {int? maxLen}) {
    final display = (maxLen != null && value.length > maxLen) 
        ? '${value.substring(0, maxLen)}…' 
        : value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10)),
          ),
          Expanded(
            child: Text(display, style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  /// GPS调试详情弹窗 - 显示最近的GPS日志
  void _showGpsDebugDetail() {
    final logs = GpsDebugLogger.instance.logs;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: [
            // 拖拽条
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.grey.shade600, borderRadius: BorderRadius.circular(2)),
            ),
            // 标题
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Text('GPS调试日志', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () async {
                      final path = await GpsDebugLogger.instance.exportCsv();
                      if (path != null && mounted) {
                        await Clipboard.setData(ClipboardData(text: path));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已导出: $path')),
                        );
                      }
                    },
                    icon: const Icon(Icons.download, size: 16, color: Colors.blue),
                    label: const Text('导出CSV', style: TextStyle(color: Colors.blue, fontSize: 12)),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      GpsDebugLogger.instance.clear();
                      Navigator.pop(ctx);
                      setState(() {});
                    },
                    icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                    label: const Text('清除', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF334155)),
            // 日志列表（倒序，最新在上）
            Expanded(
              child: logs.isEmpty
                  ? const Center(child: Text('暂无GPS日志', style: TextStyle(color: Color(0xFF64748B))))
                  : ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: logs.length,
                      reverse: true,
                      itemBuilder: (ctx, i) {
                        final log = logs[logs.length - 1 - i];
                        final accColor = log.accuracy <= 25
                            ? const Color(0xFF10B981)
                            : log.accuracy <= 50
                                ? const Color(0xFFF59E0B)
                                : const Color(0xFFEF4444);
                        return Container(
                          margin: const EdgeInsets.symmetric(vertical: 2),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(8),
                            border: Border(left: BorderSide(color: accColor, width: 3)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 时间 + 精度
                              Row(
                                children: [
                                  Text(
                                    '${log.time.hour}:${log.time.minute.toString().padLeft(2, '0')}:${log.time.second.toString().padLeft(2, '0')}.${log.time.millisecond.toString().padLeft(3, '0')}',
                                    style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(color: accColor.withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
                                    child: Text('${log.accuracy.toStringAsFixed(1)}m', style: TextStyle(color: accColor, fontSize: 10, fontWeight: FontWeight.w600)),
                                  ),
                                  const SizedBox(width: 4),
                                  Text('${(log.speed * 3.6).toStringAsFixed(1)}km/h', style: const TextStyle(color: Colors.white60, fontSize: 10)),
                                  if (log.isMocked) ...[
                                    const SizedBox(width: 4),
                                    const Text('模拟', style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.w600)),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${log.lat.toStringAsFixed(6)}, ${log.lng.toStringAsFixed(6)}',
                                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10, fontFamily: 'monospace'),
                              ),
                              if (log.activity != null)
                                Text('活动: ${log.activity}', style: const TextStyle(color: Color(0xFF64748B), fontSize: 10)),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(int minutes) {
    if (minutes < 60) return '$minutes分钟';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h < 24) return '${h}小时${m > 0 ? '${m}分' : ''}';
    final d = h ~/ 24;
    final rh = h % 24;
    return '${d}天${rh > 0 ? '${rh}小时' : ''}';
  }
}

// ==================== 表情炸弹粒子 ====================

class _EmojiParticle {
  final String emoji;
  double x;
  double y;
  double vy;
  double opacity;

  _EmojiParticle({
    required this.emoji,
    required this.x,
    required this.y,
    required this.vy,
    required this.opacity,
  });
}

/// 表情炸弹绘制器
class _EmojiBombPainter extends CustomPainter {
  final List<_EmojiParticle> particles;

  _EmojiBombPainter(this.particles);

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      p.y += p.vy;
      p.opacity -= 0.008;
      if (p.opacity <= 0) continue;

      final tp = TextPainter(
        text: TextSpan(text: p.emoji, style: TextStyle(fontSize: 32)),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.save();
      canvas.translate(p.x, p.y);
      tp.paint(canvas, Offset.zero);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _EmojiBombPainter oldDelegate) => true;
}

// ==================== 坐标转换工具 ====================

/// WGS-84 坐标转 GCJ-02（高德/国测局坐标）
/// 中国大陆地图瓦片使用 GCJ-02 坐标系，GPS 返回 WGS-84，需转换才对得上
LatLng _wgs84ToGcj02(double wgsLat, double wgsLng) {
  const double a = 6378245.0;
  const double ee = 0.00669342162296594323;
  if (_outOfChina(wgsLat, wgsLng)) return LatLng(wgsLat, wgsLng);
  double dLat = _transformLat(wgsLng - 105.0, wgsLat - 35.0);
  double dLng = _transformLng(wgsLng - 105.0, wgsLat - 35.0);
  double radLat = wgsLat / 180.0 * pi;
  double magic = sin(radLat);
  magic = 1 - ee * magic * magic;
  double sqrtMagic = sqrt(magic);
  dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * pi);
  dLng = (dLng * 180.0) / (a / sqrtMagic * cos(radLat) * pi);
  return LatLng(wgsLat + dLat, wgsLng + dLng);
}

/// GCJ-02 → WGS-84 近似逆转换（迭代法，精度<1米）
LatLng _gcj02ToWgs84(double gcjLat, double gcjLng) {
  if (_outOfChina(gcjLat, gcjLng)) return LatLng(gcjLat, gcjLng);
  // 迭代：WGS = GCJ - 偏移量，先设初始WGS=GCJ，逐步逼近
  double wgsLat = gcjLat, wgsLng = gcjLng;
  for (int i = 0; i < 3; i++) {
    final gcj = _wgs84ToGcj02(wgsLat, wgsLng);
    wgsLat -= (gcj.latitude - gcjLat);
    wgsLng -= (gcj.longitude - gcjLng);
  }
  return LatLng(wgsLat, wgsLng);
}

bool _outOfChina(double lat, double lng) {
  return lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;
}

double _transformLat(double x, double y) {
  double ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(x.abs());
  ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0;
  ret += (20.0 * sin(y * pi) + 40.0 * sin(y / 3.0 * pi)) * 2.0 / 3.0;
  ret += (160.0 * sin(y / 12.0 * pi) + 320 * sin(y * pi / 30.0)) * 2.0 / 3.0;
  return ret;
}

double _transformLng(double x, double y) {
  double ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(x.abs());
  ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0;
  ret += (20.0 * sin(x * pi) + 40.0 * sin(x / 3.0 * pi)) * 2.0 / 3.0;
  ret += (150.0 * sin(x / 12.0 * pi) + 300.0 * sin(x / 30.0 * pi)) * 2.0 / 3.0;
  return ret;
}

// ==================== 动画成员卡片 - 交错入场 + 选中弹性反馈 ====================

class _AnimatedMemberCard extends StatefulWidget {
  final int index;
  final bool isDark;
  final bool isSelected;
  final VoidCallback onTap;
  final Widget child;

  const _AnimatedMemberCard({
    super.key,
    required this.index,
    required this.isDark,
    required this.isSelected,
    required this.onTap,
    required this.child,
  });

  @override
  State<_AnimatedMemberCard> createState() => _AnimatedMemberCardState();
}

class _AnimatedMemberCardState extends State<_AnimatedMemberCard> {
  // 入场动画状态：首次构建时从左滑入
  bool _visible = false;

  // 确保入场动画只播放一次（同一 key）
  static final Set<Key> _playedEntrance = {};

  @override
  void initState() {
    super.initState();
    final k = widget.key;
    if (k != null && !_playedEntrance.contains(k)) {
      _playedEntrance.add(k);
      // 延迟显示，触发入场动画
      Future.delayed(Duration(milliseconds: 120 * widget.index), () {
        if (mounted) setState(() => _visible = true);
      });
    } else {
      _visible = true; // 已播放过，直接显示
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: _visible ? Offset.zero : const Offset(-0.5, 0),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: _visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOut,
        child: AnimatedScale(
          scale: widget.isSelected ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: widget.isDark ? const Color(0xFF1E293B) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: widget.isDark ? Colors.black26 : const Color(0x14000000),
                    blurRadius: 24,
                    offset: const Offset(0, 4),
                  ),
                ],
                border: widget.isSelected
                    ? Border.all(color: const Color(0xFFFF8C42), width: 1.5)
                    : null,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
