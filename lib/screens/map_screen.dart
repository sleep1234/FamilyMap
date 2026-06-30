import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Circle;
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:activity_recognition_flutter/activity_recognition_flutter.dart' as ar;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_app_badger/flutter_app_badger.dart';
import '../config.dart';
import '../models/models.dart';
import '../services/socket_service.dart';
import '../services/api_service.dart';
import '../services/local_cache_service.dart';
import '../services/gps_debug_logger.dart';
import '../services/notification_service.dart';
import '../services/tile_cache_service.dart';
import '../main.dart'; // SplashScreen（force_logout 时跳转登录页）
import '../widgets/trail_particles.dart';
import '../widgets/member_marker.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/ios_battery_icon.dart';
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

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  final MapController _mapController = MapController();
  final SocketService _socketService = SocketService();
  final ApiService _apiService = apiService;
  final CachedTileProvider _tileProvider = CachedTileProvider();

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
  Position? _lastTimerSentPosition; // 定时器上次发送的位置（避免重复发同一位置）
  Timer? _memberRefreshTimer; // 定时刷新成员列表，获取最新地址
  Timer? _geocodeDebounce; // 逆地理解码防抖
  Timer? _stayTimer; // 每分钟刷新停留时长显示
  Timer? _gpsRetryTimer; // GPS权限/服务等待重试
  Timer? _gpsWatchdogTimer; // GPS流看门狗：20秒没数据→重启
  DateTime? _lastGpsUpdateTime; // 上次收到GPS位置的时间
  int _gpsWatchdogRestarts = 0; // 看门狗连续重启计数
  String _myAddress = ''; // 自己的逆地理地址
  int _currentTab = 0;
  String _myTrailSkin = 'default'; // 自己的轨迹皮肤

  // 页面可见性标记：push 子页面时设为 false，避免后台 setState 浪费重绘
  bool _isPageVisible = true;

  // 后台状态标记：用于后台降低上报频率和省电
  bool _isInBackground = false;

  // 地图层数据版本：MarkerLayer/CircleLayer/TrailParticle 只在这个版本变化时重建
  // GPS位置、Socket成员位置、围栏变更、逆地理等数据变化时递增
  // 其他 setState（面板Tab切换、Header按钮等）不会触发地图层重建
  final ValueNotifier<int> _mapLayerVersion = ValueNotifier(0);
  void _markMapLayersDirty() => _mapLayerVersion.value++;

  // 活动识别（对标Jagat，用系统API判断是否在开车/步行/静止）
  StreamSubscription<ar.ActivityEvent>? _activityStream;
  ar.ActivityType _currentActivity = ar.ActivityType.unknown;
  ar.ActivityType _pendingActivity = ar.ActivityType.unknown;
  int _activityConfidenceCount = 0;
  static const int _activityConfidenceThreshold = 3; // 连续3次相同才切换

  // 1.4 速度滤波：指数加权移动平均（EWMA），比简单平均响应更快
  double _ewmaSpeed = 0.0; // 当前滤波速度
  static const double _ewmaAlpha = 0.4; // 新值权重 0.4，旧值 0.6（0=all old, 1=no filter）
  // 辅助：近期最大速度（用于判断是否刚从高速减速，避免过早归零）
  double _recentMaxSpeed = 0.0;
  static const int _maxSpeedDecayFrames = 5; // 最大速度衰减帧数
  int _maxSpeedDecayCounter = 0;

  // 1.1 自适应上报频率：根据移动状态动态调整定时器间隔
  // 驾车高速1s，驾车2s，步行/骑行5s，静止15s
  Duration _currentReportInterval = const Duration(seconds: 5);
  Position? _lastReportedPosition; // 上次上报位置，用于GPS跳点检测

  // 围栏创建：长按地图选点
  LatLng? _geofencePinPos; // 围栏钉子位置（GCJ-02）
  bool _isPlacingGeofence = false; // 是否在选择围栏位置

  // 4.5 热力图
  bool _showHeatmap = false; // 是否显示热力图
  List<Map<String, dynamic>> _heatmapPoints = []; // 热力图数据点

  // 世界迷雾
  bool _showWorldFog = false; // 是否显示迷雾遮罩
  List<FogGrid> _worldFogGrids = []; // 已探索的网格点

  // GPS调试
  bool _gpsDebugEnabled = false;
  // GPS初始化状态追踪
  String _gpsInitStatus = '未初始化'; // 供调试框显示
  bool _gpsStreamActive = false; // 位置流是否已启动

  // 群聊未读消息计数
  int _unreadChatCount = 0;
  bool _isChatScreenOpen = false; // 聊天页面是否打开中

  // 位置插值定时器：让成员标记在新位置到来时平滑移动而非瞬移
  Timer? _interpolationTimer;
  Timer? _iosBatteryTimer;
  DateTime _lastInterpolationTime = DateTime.now();

  // 电池信息
  final Battery _battery = Battery();
  int? _myBatteryLevel;
  bool _myCharging = false;
  StreamSubscription<BatteryState>? _batterySub;
  String _batteryDiag = ''; // 电池诊断信息（iOS 调试用，正常为空）

  // Socket 事件订阅（统一管理，dispose 时批量取消）
  final List<StreamSubscription> _socketSubscriptions = [];

  // 可拖动底部面板 - 三档弹簧吸附
  // 使用 ValueNotifier 拖拽时只重建面板本身，不触发整个 MapScreen setState
  final ValueNotifier<double> _panelHeightNotifier = ValueNotifier(140);
  double get _panelHeight => _panelHeightNotifier.value;
  static const double _panelPeek = 140;   // Tab栏 + 首行成员（大字体也够）
  static const double _panelHalf = 300;   // 半屏
  static const double _panelFull = 550;   // 全屏
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
    _panelHeightNotifier.value = target;
  }

  // 表情炸弹动画
  List<_EmojiParticle> _emojiParticles = [];

  /// 是否处于暗黑模式（统一判断入口）
  bool get _isDark => widget.darkMode || _userSettings?.darkMode == true;

  @override
  void initState() {
    super.initState();
    _tileProvider.init();
    WidgetsBinding.instance.addObserver(this); // 注册生命周期观察
    _onlineMembers.add(widget.currentUser.id); // 自己在线
    _socketService.connect(widget.currentUser.id, token: widget.currentUser.token);
    _listenSocketEvents();
    // 先从本地缓存加载圈子和成员列表（启动秒展示），再后台刷新API
    _loadCircles(fromCache: true);
    _loadCircles(); // 后台静默刷新
    _loadSettings();
    _loadGpsDebugFlag(); // 读取GPS调试开关
    // 注册通知点击回调（微信风格：点击通知跳转到对应页面）
    NotificationService().onTap = _onNotificationTapped;
    // 先请求定位权限（核心功能），权限拿到后再初始化位置和电池，
    // 最后才请求通知权限（辅助功能），避免多个权限弹窗互相阻塞
    _requestLocationAndInit();
    // 启动位置插值定时器（30fps），让成员标记平滑移动
    _startInterpolationTimer();
  }

  /// 按优先级顺序请求权限并初始化：通知(前台服务必需) → 位置 → 电池 → 活动识别
  Future<void> _requestLocationAndInit() async {
    // 0. 先用缓存位置立即显示地图（不等GPS，消除启动时的"空白等待"）
    await _restoreCachedPosition();
    // 1. 通知权限（非阻塞：后台初始化，不等待结果。前台服务启动时权限已就绪）
    _initNotifications();
    // 2. 电池（不依赖位置权限，独立初始化）
    _initBattery();
    // 3. 位置权限（可能阻塞等待用户授权，放后面不影响电池）
    _initLocation();
    // 4. 活动识别
    _initActivityRecognition();
  }

  /// 从 SharedPreferences 恢复上次缓存的坐标+电池状态，立即定位地图
  Future<void> _restoreCachedPosition() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lat = prefs.getDouble('cached_lat');
      final lng = prefs.getDouble('cached_lng');
      final battery = prefs.getInt('cached_battery');
      final charging = prefs.getBool('cached_charging');

      if (lat != null && lng != null) {
        debugPrint('[缓存] 恢复上次位置: $lat, $lng (battery=$battery, charging=$charging)');
        // 恢复电池状态
        if (battery != null) _myBatteryLevel = battery;
        if (charging != null) _myCharging = charging;

        // 立即移动地图到缓存位置
        final gcjPos = _wgs84ToGcj02(lat, lng);
        _mapController.move(gcjPos, 15);

        // 立即显示自己的标记
        final myKey = widget.currentUser.id;
        _memberTrails[myKey] = MemberTrail(
          userId: myKey,
          name: widget.currentUser.name,
          color: _parseColor(widget.currentUser.avatarColor),
          currentPos: gcjPos,
        );

        setState(() {});
      }
    } catch (e) {
      debugPrint('[缓存] 恢复缓存位置失败: $e');
    }
  }

  DateTime? _lastCacheTime; // 上次缓存时间，用于防抖

  /// 将当前位置和电池状态缓存到 SharedPreferences（防抖：30秒内不重复写入）
  Future<void> _cachePosition({bool force = false}) async {
    try {
      final now = DateTime.now();
      if (!force && _lastCacheTime != null && now.difference(_lastCacheTime!).inSeconds < 30) return;
      _lastCacheTime = now;
      final pos = _currentPosition;
      if (pos == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('cached_lat', pos.latitude);
      await prefs.setDouble('cached_lng', pos.longitude);
      if (_myBatteryLevel != null) await prefs.setInt('cached_battery', _myBatteryLevel!);
      await prefs.setBool('cached_charging', _myCharging);
    } catch (e) {
      debugPrint('[缓存] 保存位置缓存失败: $e');
    }
  }

  /// 从 _members 中查找成员头像 URL
  String? _getMemberAvatarUrl(String userId) {
    try {
      final idx = _members.indexWhere((m) => m['id'] == userId);
      if (idx >= 0) return _members[idx]['avatar_url'] as String?;
    } catch (_) {}
    return null;
  }

  /// 初始化系统通知服务，请求通知权限，显示前台常驻通知
  Future<void> _initNotifications() async {
    final notif = NotificationService();
    await notif.init();
    final granted = await notif.requestPermission();
    if (!granted && mounted) {
      // 权限被拒绝，提示用户去设置开启
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('通知权限未开启，部分提醒可能无法显示'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: '去设置',
            onPressed: () => notif.openNotificationSettings(),
          ),
        ),
      );
    }
    // 显示前台服务常驻通知（表示位置共享活跃）
    await notif.showForegroundNotification(
      title: 'FamilyMap',
      body: '位置共享服务运行中',
    );
  }

  Future<void> _loadGpsDebugFlag() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('gps_debug') ?? false;
    GpsDebugLogger.instance.enabled = enabled;
    if (mounted) setState(() => _gpsDebugEnabled = enabled);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // 移除生命周期观察
    _positionStream?.cancel();
    _periodicSendTimer?.cancel();
    _memberRefreshTimer?.cancel();
    _geocodeDebounce?.cancel();
    _stayTimer?.cancel();
    _gpsRetryTimer?.cancel();
    _gpsWatchdogTimer?.cancel();
    _interpolationTimer?.cancel();
    _iosBatteryTimer?.cancel();
    _activityStream?.cancel();
    _batterySub?.cancel();
    // 取消通知点击回调
    NotificationService().onTap = null;
    // 取消 Socket 事件订阅（不 dispose SocketService 单例，ChatScreen 等页面也在用）
    _cancelSocketSubscriptions();
    _socketService.disconnect();
    // 关闭前台常驻通知
    NotificationService().cancelForegroundNotification();
    // 清除桌面图标角标
    try { FlutterAppBadger.removeBadge(); } catch (_) {}
    _panelHeightNotifier.dispose();
    _mapLayerVersion.dispose();
    super.dispose();
  }

  /// App 生命周期感知：后台暂停资源密集型操作，前台恢复
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // 进入后台：暂停所有非必要定时器，大幅降低耗电
      _isInBackground = true;
      _memberRefreshTimer?.cancel();
      _stayTimer?.cancel();
      // 暂停30fps插值动画（纯UI渲染，后台无用）
      _interpolationTimer?.cancel();
      // 暂停GPS流看门狗（后台无需监控GPS健康）
      _gpsWatchdogTimer?.cancel();
      // 暂停iOS电量轮询（电量变化缓慢，后台不需要10秒刷新）
      if (Platform.isIOS) _iosBatteryTimer?.cancel();
      // 暂停活动识别（后台已有上一次结果可用）
      _activityStream?.cancel();
      // 强制缓存一次位置
      _cachePosition(force: true);
      // 立即切换到后台上报间隔（更长周期省电）
      _updateReportInterval();
      debugPrint('[生命周期] 应用进入后台，已暂停插值/看门狗/电量/活动识别，上报间隔已拉长');
    } else if (state == AppLifecycleState.resumed) {
      _isInBackground = false;
      // 回到前台：恢复所有定时器
      _memberRefreshTimer?.cancel();
      _memberRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (_isPageVisible) _loadMembers();
      });
      _stayTimer?.cancel();
      _stayTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted && _isPageVisible && _members.any((m) => m['stay_started_at'] != null)) {
          setState(() {});
        }
      });
      // 恢复30fps插值动画
      _startInterpolationTimer();
      // 恢复GPS看门狗
      _gpsWatchdogTimer?.cancel();
      _gpsWatchdogTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (!mounted) return;
        final lastUpdate = _lastGpsUpdateTime;
        final elapsed = lastUpdate != null
            ? DateTime.now().difference(lastUpdate).inSeconds
            : 999;
        if (elapsed > 20) {
          _gpsWatchdogRestarts++;
          _gpsStreamActive = false;
          _isLocationSharing = false;
          try { _positionStream?.cancel(); } catch (_) {}
          _positionStream = null;
          if (mounted) setState(() {});
          if (_gpsWatchdogRestarts > 3) {
            _gpsWatchdogRestarts = 0;
            _initLocation();
            return;
          }
          _startLocationSharing();
        } else {
          if (_gpsWatchdogRestarts > 0) _gpsWatchdogRestarts = 0;
        }
      });
      // 恢复iOS电量轮询
      if (Platform.isIOS) _initBatteryIOS();
      // 恢复活动识别
      _initActivityRecognition();
      // 恢复前台上报间隔（更短周期更实时）
      _updateReportInterval();
      debugPrint('[生命周期] 应用回到前台，已恢复所有定时器，上报间隔已恢复');
    }
  }

  /// 批量取消 Socket 事件订阅
  void _cancelSocketSubscriptions() {
    for (final sub in _socketSubscriptions) {
      sub.cancel();
    }
    _socketSubscriptions.clear();
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

    // Android 13+ (API 33+): whileInUse 说明前台权限已获得，但后台位置权限尚未授予
    // whileInUse 是 Android 13 新增的权限状态，12 及以下只会返回 granted/denied/deniedForever
    // iOS: 获得whileInUse后也需要升级为always才能后台追踪
    // 不授予后台权限 → 前台服务在后台时无法接收位置更新 → 位置不同步
    if (permission == LocationPermission.whileInUse) {
      _gpsInitStatus = '正在请求后台位置权限…';
      if (mounted) setState(() {});
      // 再次调用 requestPermission()，Android 13+ 会弹出"升级为始终允许"对话框
      // iOS 也会弹出升级权限的对话框
      final bgPermission = await Geolocator.requestPermission();
      if (bgPermission == LocationPermission.always) {
        debugPrint('[定位] 已获得后台位置权限（始终允许）');
      } else if (bgPermission == LocationPermission.whileInUse) {
        debugPrint('[定位] 用户仅授予前台位置权限，后台追踪可能受限');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('建议开启"始终允许"位置权限，以确保后台位置共享正常工作'),
              duration: Duration(seconds: 5),
              action: SnackBarAction(
                label: '去设置',
                onPressed: Geolocator.openAppSettings,
              ),
            ),
          );
        }
      }
      // 即使用户拒绝后台权限，也不阻塞，继续使用前台权限
    }

    _gpsInitStatus = '正在获取GPS定位…';
    if (mounted) setState(() {});

    // 带超时获取位置，避免GPS信号弱时无限等待
    Position? pos;
    try {
      // 平台适配：Android 用 AndroidSettings，iOS 用通用 LocationSettings
      if (Platform.isAndroid) {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: AndroidSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
            forceLocationManager: true,
          ),
        );
      } else {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        );
      }
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
          skinId: _myTrailSkin,
        );

      _gpsInitStatus = 'GPS已定位（精度${pos.accuracy.toStringAsFixed(0)}m）';
      _cachePosition(); // 缓存位置供下次启动使用
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
        batteryLevel: _myBatteryLevel,
        isCharging: _myCharging,
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
      // 先从缓存加载
      final cached = await LocalCacheService.instance.getUserSettings(widget.currentUser.id);
      if (cached != null) {
        try {
          final s = UserSettings.fromJson(cached);
          setState(() => _userSettings = s);
          _myTrailSkin = s.trailSkin;
          final myKey = widget.currentUser.id;
          if (_memberTrails.containsKey(myKey)) {
            _memberTrails[myKey]!.skinId = _myTrailSkin;
          }
          if (s.darkMode != widget.darkMode) {
            widget.onDarkModeChanged(s.darkMode);
          }
        } catch (_) {}
      }
      // 后台刷新
      final s = await _apiService.getUserSettings(widget.currentUser.id);
      setState(() => _userSettings = s);
      // 保存到缓存
      await LocalCacheService.instance.saveUserSettings(widget.currentUser.id, s.toJson());
      // 同步轨迹皮肤
      _myTrailSkin = s.trailSkin;
      // 同步自己 MemberTrail 的 skinId
      final myKey = widget.currentUser.id;
      if (_memberTrails.containsKey(myKey)) {
        _memberTrails[myKey]!.skinId = _myTrailSkin;
      }
      // 同步暗黑模式到全局主题（确保服务器设置与App主题一致）
      if (s.darkMode != widget.darkMode) {
        widget.onDarkModeChanged(s.darkMode);
      }
      // 更新前台通知文字（反映位置共享状态）
      if (s.sharePaused) {
        NotificationService().showForegroundNotification(
          title: 'FamilyMap',
          body: '位置共享已暂停',
        );
      } else {
        NotificationService().showForegroundNotification(
          title: 'FamilyMap',
          body: '位置共享服务运行中',
        );
      }
    } catch (_) {}
  }

  /// 4.5 加载热力图数据（当前用户，默认近7天）
  Future<void> _loadHeatmap() async {
    try {
      final data = await _apiService.getHeatmap(widget.currentUser.id, days: 7);
      final points = (data['heatmap'] as List).cast<Map<String, dynamic>>();
      _heatmapPoints = points;
      _markMapLayersDirty();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('热力图加载失败: $e');
    }
  }

  /// 切换热力图显示
  void _toggleHeatmap() {
    _showHeatmap = !_showHeatmap;
    _markMapLayersDirty();
    setState(() {});
    if (_showHeatmap && _heatmapPoints.isEmpty) {
      _loadHeatmap();
    }
  }

  // ==================== 活动识别（对标Jagat）====================

  /// 初始化电池信息监听
  Future<void> _initBattery() async {
    if (Platform.isIOS) {
      await _initBatteryIOS();
    } else {
      await _initBatteryAndroid();
    }
  }

  /// iOS 电池：只用 battery_plus.batteryLevel 轮询，绝不订阅 stream
  Future<void> _initBatteryIOS() async {
    _batteryDiag = 'INIT'; // 立即标记，证明函数进入了
    if (mounted) setState(() {});

    await _refreshBatteryIOS();

    _iosBatteryTimer?.cancel();
    _iosBatteryTimer = Timer.periodic(const Duration(seconds: 10), (_) => _refreshBatteryIOS());
  }

  /// iOS 轮询电池：直接调 battery_plus.batteryLevel（加超时保护）
  Future<void> _refreshBatteryIOS() async {
    try {
      // 加 5 秒超时，防止 Future 永远不完成
      final level = await _battery.batteryLevel.timeout(const Duration(seconds: 5), onTimeout: () => -1);
      final state = await _battery.batteryState.timeout(const Duration(seconds: 5), onTimeout: () => BatteryState.unknown);
      if (level < 0) {
        _batteryDiag = 'TIMEOUT lv=$level';
      } else {
        final wasCharging = _myCharging;
        final oldLevel = _myBatteryLevel;
        _myBatteryLevel = level;
        _myCharging = state == BatteryState.charging;
        _batteryDiag = 'OK lv=$level ${state.name}';
        // 电量或充电状态变化时都上报
        if (wasCharging != _myCharging || oldLevel != level) {
          _reportBatteryChange();
        }
        _markMapLayersDirty();
      }
    } catch (e) {
      _batteryDiag = 'ERR: $e';
    }
    if (mounted) setState(() {});
  }

  /// Android 电池：用 battery_plus 插件（stream 监听）
  Future<void> _initBatteryAndroid() async {
    try {
      _myBatteryLevel = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      _myCharging = state == BatteryState.charging;
    } catch (e) {
      debugPrint('[电池-Android] 初始化失败: $e');
    }
    if (mounted) setState(() {});

    _batterySub = _battery.onBatteryStateChanged.listen((state) async {
      try {
        final level = await _battery.batteryLevel;
        final wasCharging = _myCharging;
        if (mounted) {
          _myBatteryLevel = level;
          _myCharging = state == BatteryState.charging;
          _markMapLayersDirty();
        }
        if (wasCharging != _myCharging) _reportBatteryChange();
      } catch (e) {
        debugPrint('[电池-Android] 监听失败: $e');
      }
    });
  }

  /// 充电状态变化时，用最近已知位置立即上报一次，并同步更新成员列表
  void _reportBatteryChange() {
    final pos = _lastReportedPosition;
    if (pos == null) return;
    _socketService.sendLocationUpdate(
      userId: widget.currentUser.id,
      latitude: pos.latitude,
      longitude: pos.longitude,
      accuracy: pos.accuracy,
      speed: _effectiveSpeed,
      batteryLevel: _myBatteryLevel,
      isCharging: _myCharging,
    );
    debugPrint('[电池] 充电状态变化 → 立即上报 isCharging=$_myCharging, level=$_myBatteryLevel');

    // 同时更新成员列表中自己的数据，不等服务端回传
    _syncSelfBatteryToMembers();
    _cachePosition(); // 电池状态也要缓存
  }

  /// 将本机电池状态同步到 _members 中自己的条目（立即刷新成员列表UI）
  void _syncSelfBatteryToMembers() {
    if (_myBatteryLevel == null) return;
    final myId = widget.currentUser.id;
    final idx = _members.indexWhere((m) => m['id'] == myId);
    if (idx >= 0) {
      setState(() {
        _members[idx]['battery_level'] = _myBatteryLevel;
        _members[idx]['is_charging'] = _myCharging ? 1 : 0;
      });
    }
  }

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
      _currentActivity = _pendingActivity;
      _markMapLayersDirty(); // 活动类型变化 → 刷新地图标记上的移动标签
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
        // 活动识别不可用时，用有效速度判断
        final spd = _effectiveSpeed;
        if (spd < 1.0) return MovementType.still;
        if (spd < 3.5) return MovementType.walking;
        if (spd < 8.0) return MovementType.cycling;
        return MovementType.driving;
    }
  }

  /// 获取EWMA滤波速度
  double _getFilteredSpeed() => _ewmaSpeed;

  /// 获取当前有效速度
  /// - 精度 > 20m → 0（GPS信号极差，速度完全不可信）
  /// - EWMA速度 < 0.5km/h（0.14m/s）→ 0（排除极低速噪声）
  /// - 否则用EWMA滤波速度
  double get _effectiveSpeed {
    // 精度极差时速度不可信
    final accuracy = _currentPosition?.accuracy ?? 999;
    if (accuracy > 20) return 0.0;
    // 极低速视为静止
    if (_ewmaSpeed < 0.14) return 0.0; // 0.14m/s ≈ 0.5km/h
    return _isCurrentlyMoving ? _ewmaSpeed : 0.0;
  }

  /// 当前是否在移动（活动识别 + 速度双判断）
  bool get _isCurrentlyMoving {
    // 活动识别明确在移动
    if (_currentActivity == ar.ActivityType.inVehicle ||
        _currentActivity == ar.ActivityType.onBicycle ||
        _currentActivity == ar.ActivityType.onFoot ||
        _currentActivity == ar.ActivityType.walking ||
        _currentActivity == ar.ActivityType.running) {
      return true;
    }
    // unknown/still 时用EWMA速度判断
    if (_currentActivity == ar.ActivityType.unknown ||
        _currentActivity == ar.ActivityType.still) {
      return _ewmaSpeed > 0.5; // 0.5m/s ≈ 1.8km/h，慢走起步
    }
    return false;
  }

  // ==================== 位置共享 ====================

  int _locationSharingGeneration = 0; // 用于防止异步竞态

  Future<void> _startLocationSharing() async {
    // 防止并发：如果已经在启动中或运行中，跳过
    if (_isLocationSharing) {
      debugPrint('[GPS] _startLocationSharing 被跳过：_isLocationSharing=true');
      return;
    }
    _isLocationSharing = true;
    _gpsStreamActive = false; // 先标为未激活，等收到第一个数据再标true
    final myGeneration = ++_locationSharingGeneration; // 记录本次调用的代号
    debugPrint('[GPS] _startLocationSharing 开始执行 (gen=$myGeneration)');

    // 清理旧资源（防止重复创建 GPS 流和定时器）
    // 重要：用 try-catch 包裹 cancel，防止异常导致整个函数退出（新流不会创建）
    try {
      await _positionStream?.cancel();
      debugPrint('[GPS] 旧 positionStream 已取消');
    } catch (e) {
      debugPrint('[GPS] 取消旧 positionStream 出错（可忽略）: $e');
    }
    _positionStream = null; // 确保清空引用
    try {
      _periodicSendTimer?.cancel();
    } catch (e) {
      debugPrint('[GPS] 取消 periodicSendTimer 出错（可忽略）: $e');
    }

    // 监听GPS位置变化
    // Android 需要前台服务通知才能在后台持续收到位置更新
    // distanceFilter: 有后台权限时用5米过滤（节能），无后台权限时用1米（0在部分ROM上会导致流无数据）
    final hasBgPermission = await Geolocator.checkPermission() == LocationPermission.always;
    // 检查是否已被看门狗或其他调用抢占
    if (myGeneration != _locationSharingGeneration) {
      debugPrint('[GPS] _startLocationSharing 被抢占 (gen=$myGeneration != ${_locationSharingGeneration})，放弃');
      _isLocationSharing = false;
      return;
    }
    debugPrint('[GPS] hasBgPermission=$hasBgPermission, 准备创建 getPositionStream');

    // 平台适配：Android 用 AndroidSettings（前台服务+forceLocationManager），iOS 用 AppleSettings
    LocationSettings locationSettings;
    if (Platform.isAndroid) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        // 不用 forceLocationManager！用 Google Play Services 的 FusedLocationProvider
        // FusedLocationProvider 专为后台持续定位设计，配合前台服务能保持高频更新
        // forceLocationManager=true 强制用老 LocationManager，后台极易被系统节流
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationText: '正在后台追踪您的位置',
          notificationTitle: 'FamilyMap',
          notificationChannelName: '后台位置追踪',
          enableWakeLock: true,
          notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
          setOngoing: true,
        ),
        intervalDuration: const Duration(seconds: 1),
      );
    } else {
        // iOS: 使用 AppleSettings 开启后台定位
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        // 允许后台位置更新（必须配合 Info.plist UIBackgroundModes=location）
        allowBackgroundLocationUpdates: true,
        // 不自动暂停位置更新（锁屏后继续追踪）
        pauseLocationUpdatesAutomatically: false,
        // 隐藏灵动岛蓝色箭头指示器（隐私敏感场景可设为 true）
        showBackgroundLocationIndicator: false,
        activityType: ActivityType.other,
      );
    }

    _positionStream = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (pos) {
        if (!_gpsStreamActive) {
          _gpsStreamActive = true;
          debugPrint('[GPS] 收到第一个位置数据！精度${pos.accuracy.toStringAsFixed(0)}m, isMocked=${pos.isMocked}');
        }
        _lastGpsUpdateTime = DateTime.now(); // 喂狗
        _handlePositionUpdate(pos);
      },
      onError: (e) {
        debugPrint('[定位] 位置流出错: $e');
        _gpsStreamActive = false;
        _gpsInitStatus = '位置流出错: $e，5秒后重试';
        if (mounted) setState(() {});
        _isLocationSharing = false;
        try { _positionStream?.cancel(); } catch (_) {}
        _gpsWatchdogTimer?.cancel();
        // 使用可取消的 Timer 代替 Future.delayed，防止与模拟模式竞态
        _gpsRetryTimer?.cancel();
        _gpsRetryTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) _startLocationSharing();
        });
      },
      onDone: () {
        debugPrint('[GPS] 位置流 onDone —— 流已关闭（通常不应发生）');
        _gpsStreamActive = false;
        _isLocationSharing = false;
        _gpsInitStatus = '位置流已关闭，5秒后重启';
        if (mounted) setState(() {});
        _gpsRetryTimer?.cancel();
        _gpsRetryTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) _startLocationSharing();
        });
      },
      cancelOnError: false,
    );
    debugPrint('[GPS] getPositionStream.listen 已注册，等待数据...');

    // 自适应上报定时器：根据移动状态动态调整间隔
    // 每次发送后都重新检查间隔（后台GPS流慢时，定时器仍能自我调整）
    // 关键：只有位置实际变化时才上报，避免后台GPS节流时重复发同一位置
    _periodicSendTimer?.cancel();
    _periodicSendTimer = Timer.periodic(_currentReportInterval, (_) {
      // 自我调整：即使GPS流被后台节流，定时器也能根据最新速度更新间隔
      _updateReportInterval();
      if (_currentPosition != null && _userSettings?.sharePaused != true) {
        // 检查位置是否真的变了（GPS流后台被节流时，_currentPosition 可能长时间不变）
        final cur = _currentPosition!;
        final last = _lastTimerSentPosition;
        final posChanged = last == null ||
            (cur.latitude - last.latitude).abs() > 0.000001 ||
            (cur.longitude - last.longitude).abs() > 0.000001;
        if (posChanged) {
          _socketService.sendLocationUpdate(
            userId: widget.currentUser.id,
            latitude: cur.latitude,
            longitude: cur.longitude,
            accuracy: cur.accuracy,
            speed: _effectiveSpeed,
            batteryLevel: _myBatteryLevel,
            isCharging: _myCharging,
          );
          _lastTimerSentPosition = cur;
        }
      }
    });

    // 每30秒刷新成员列表
    _memberRefreshTimer?.cancel();
    _memberRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_isPageVisible) _loadMembers();
    });

    // 每分钟刷新 UI，让停留时长实时递增
    _stayTimer?.cancel();
    _stayTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _isPageVisible && _members.any((m) => m['stay_started_at'] != null)) {
        setState(() {}); // 重新构建 UI，stay_minutes 会基于 stay_started_at 实时计算
      }
    });

    // GPS流看门狗：每15秒检查一次，如果20秒没收到GPS数据，强制重启定位流
    // 这解决了GPS流在长时间运行后可能静默停止的问题
    // 注意：_lastGpsUpdateTime 仅在收到真实GPS数据时更新（不在启动时重置）
    // 这样如果流创建后永远不回调，看门狗也能在20秒后检测到
    _gpsWatchdogTimer?.cancel();
    _gpsWatchdogTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      // 如果流应该运行但从未收到数据，或上次数据太久之前，都需要重启
      final lastUpdate = _lastGpsUpdateTime;
      final elapsed = lastUpdate != null
          ? DateTime.now().difference(lastUpdate).inSeconds
          : 999; // 从未收到数据，视为超时
      if (elapsed > 20) {
        _gpsWatchdogRestarts++;
        debugPrint('[看门狗] GPS流 ${elapsed}秒无数据，强制重启定位... (第${_gpsWatchdogRestarts}次)');
        debugPrint('[看门狗] 当前状态: _isLocationSharing=$_isLocationSharing, _gpsStreamActive=$_gpsStreamActive');
        // 彻底停止当前一切，然后重新启动
        _gpsStreamActive = false;
        _isLocationSharing = false;
        try { _positionStream?.cancel(); } catch (_) {}
        _positionStream = null;
        if (mounted) setState(() {});

        // 连续重启超过3次仍无数据 → 尝试完全重新初始化GPS（重新检查权限+获取位置）
        if (_gpsWatchdogRestarts > 3) {
          debugPrint('[看门狗] 连续${_gpsWatchdogRestarts}次重启仍无数据，执行完整GPS重新初始化');
          _gpsWatchdogRestarts = 0; // 重置计数
          _gpsInitStatus = 'GPS重启中（完整初始化）…';
          _initLocation();
          return;
        }
        _gpsInitStatus = 'GPS流停滞，重启中…';
        _startLocationSharing();
      } else {
        // 收到数据了，重置重启计数
        if (_gpsWatchdogRestarts > 0) {
          debugPrint('[看门狗] GPS数据恢复正常，重置重启计数');
          _gpsWatchdogRestarts = 0;
        }
      }
    });
  }

  /// 启动位置插值定时器（30fps），让成员标记平滑移动而非瞬移
  void _startInterpolationTimer() {
    _interpolationTimer?.cancel();
    _lastInterpolationTime = DateTime.now();
    _interpolationTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      final now = DateTime.now();
      final dt = now.difference(_lastInterpolationTime).inMilliseconds / 1000.0;
      _lastInterpolationTime = now;
      if (dt <= 0 || dt > 0.5) return; // 跳过异常帧

      bool anyChanged = false;
      for (final trail in _memberTrails.values) {
        if (trail.needsInterpolation) {
          trail.interpolate(dt);
          anyChanged = true;
        }
      }
      if (anyChanged) {
        _markMapLayersDirty();
      }
    });
  }

  /// 单独重启定时上报定时器（不重建 GPS 流，用于 onResume 恢复）
  void _restartPeriodicSendTimer() {
    _periodicSendTimer?.cancel();
    _lastTimerSentPosition = null; // 重置，确保恢复后立即发送
    _periodicSendTimer = Timer.periodic(_currentReportInterval, (_) {
      _updateReportInterval(); // 自我调整间隔
      if (_currentPosition != null && _userSettings?.sharePaused != true) {
        final cur = _currentPosition!;
        final last = _lastTimerSentPosition;
        final posChanged = last == null ||
            (cur.latitude - last.latitude).abs() > 0.000001 ||
            (cur.longitude - last.longitude).abs() > 0.000001;
        if (posChanged) {
          _socketService.sendLocationUpdate(
            userId: widget.currentUser.id,
            latitude: cur.latitude,
            longitude: cur.longitude,
            accuracy: cur.accuracy,
            speed: _effectiveSpeed,
            batteryLevel: _myBatteryLevel,
            isCharging: _myCharging,
          );
          _lastTimerSentPosition = cur;
        }
      }
    });
  }

  /// 更新自适应上报频率（根据移动状态，后台时拉长间隔省电）
  void _updateReportInterval() {
    final moveType = _getMovementType();
    Duration newInterval;
    if (_isInBackground) {
      // 后台：使用 2-3 倍于前台的间隔，大幅降低耗电
      if (moveType == MovementType.driving) {
        newInterval = const Duration(seconds: 5);  // 前台1-2s → 后台5s
      } else if (moveType == MovementType.cycling || moveType == MovementType.walking) {
        newInterval = const Duration(seconds: 15); // 前台5s → 后台15s
      } else {
        newInterval = const Duration(seconds: 30); // 前台15s → 后台30s
      }
    } else {
      // 前台：原有自适应逻辑
      if (moveType == MovementType.driving) {
        final spd = _effectiveSpeed;
        newInterval = spd > 16.7
            ? const Duration(seconds: 1)
            : const Duration(seconds: 2);
      } else {
        switch (moveType) {
          case MovementType.cycling:
          case MovementType.walking:
            newInterval = const Duration(seconds: 5);
            break;
          case MovementType.still:
            newInterval = const Duration(seconds: 15);
            break;
          case MovementType.driving:
            newInterval = const Duration(seconds: 2);
            break;
        }
      }
    }

    if (newInterval != _currentReportInterval) {
      _currentReportInterval = newInterval;
      // 重启定时器（回调含自我调整+去重）
      _periodicSendTimer?.cancel();
      _periodicSendTimer = Timer.periodic(_currentReportInterval, (_) {
        _updateReportInterval(); // 自我调整间隔
        if (_currentPosition != null && _userSettings?.sharePaused != true) {
          final cur = _currentPosition!;
          final last = _lastTimerSentPosition;
          final posChanged = last == null ||
              (cur.latitude - last.latitude).abs() > 0.000001 ||
              (cur.longitude - last.longitude).abs() > 0.000001;
          if (posChanged) {
            _socketService.sendLocationUpdate(
              userId: widget.currentUser.id,
              latitude: cur.latitude,
              longitude: cur.longitude,
              accuracy: cur.accuracy,
              speed: _effectiveSpeed,
              batteryLevel: _myBatteryLevel,
              isCharging: _myCharging,
            );
            _lastTimerSentPosition = cur;
          }
        }
      });
      debugPrint('[自适应] 上报间隔已调整为: ${newInterval.inSeconds}秒 (${moveType.name})');
    }
  }

  /// 处理位置更新（GPS流 + 定时发送共用）
  void _handlePositionUpdate(Position pos, {bool forceUpdate = false}) async {
    // 收到位置更新，更新GPS状态
    _gpsInitStatus = 'GPS已定位（精度${pos.accuracy.toStringAsFixed(0)}m）';

    // 1. GPS跳点检测：与上次上报位置比较
    if (_lastReportedPosition != null && !forceUpdate) {
      final dist = const Distance().distance(
        LatLng(_lastReportedPosition!.latitude, _lastReportedPosition!.longitude),
        LatLng(pos.latitude, pos.longitude),
      );

      // 1a. 超速跳点：距离/时间 > 300km/h → 丢弃
      final dt = pos.timestamp.difference(_lastReportedPosition!.timestamp).inMilliseconds / 1000;
      if (dt > 0 && dist / dt > 83.3) { // 83.3m/s = 300km/h
        debugPrint('[GPS] 超速跳点丢弃: ${dist.toStringAsFixed(0)}m/${dt.toStringAsFixed(1)}s = ${(dist/dt*3.6).toStringAsFixed(0)}km/h');
        _lastReportedPosition = pos;
        return;
      }

      // 1b. 位置横跳过滤：新位置距离 > 500m 且精度比上次差 → 丢弃
      //     典型场景：关闭模拟软件后，FusedLocationProvider 缓存的旧模拟位置（远+精度差）
      //     仍然偶尔返回，导致标记在真实位置和模拟位置间反复横跳
      //     地图软件内部都有类似过滤，我们没有所以会横跳
      if (dist > 500 && pos.accuracy > _lastReportedPosition!.accuracy) {
        debugPrint('[GPS] 横跳丢弃: 距离${dist.toStringAsFixed(0)}m, 新精度${pos.accuracy.toStringAsFixed(0)}m > 旧精度${_lastReportedPosition!.accuracy.toStringAsFixed(0)}m');
        return; // 不更新 _lastReportedPosition，让下次继续和好的位置比较
      }
    }

    // 更新位置数据 + 只刷新地图层，不触发全局 setState（面板/Header 不受 GPS 高频更新影响）
    _currentPosition = pos;
    _markMapLayersDirty();
    _cachePosition(); // 每次位置更新都缓存，供下次启动快速恢复

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

    // 2. 更新速度EWMA滤波
    //    精度 > 20m 时速度不可信（室内多径反射导致位置抖动），强制为0
    //    但位置仍然接受（室内家人需要看到你在哪）
    if (pos.accuracy <= 20) {
      final rawSpeed = pos.speed;
      // EWMA：新速度 = α × 本次速度 + (1-α) × 上次滤波速度
      // α=0.4 比简单9点平均响应快得多：90%响应需 ~4步 vs 9步
      _ewmaSpeed = _ewmaAlpha * rawSpeed + (1 - _ewmaAlpha) * _ewmaSpeed;
      // 更新近期最大速度（用于急减速检测等）
      if (rawSpeed > _recentMaxSpeed) {
        _recentMaxSpeed = rawSpeed;
        _maxSpeedDecayCounter = _maxSpeedDecayFrames;
      } else if (_maxSpeedDecayCounter > 0) {
        _maxSpeedDecayCounter--;
        if (_maxSpeedDecayCounter == 0) _recentMaxSpeed = _ewmaSpeed;
      }
    }
    // 精度 > 20m 时不更新 _ewmaSpeed，保留上次好的速度值
    // _effectiveSpeed getter 会因精度差返回 0.0

    // 暂停共享时不发送位置
    if (_userSettings?.sharePaused == true) return;

    // 自适应上报频率：检查是否需要调整
    _updateReportInterval();

    final effectiveSpeed = _effectiveSpeed;

    // 上报位置：直接用当前位置（室内精度差也上报，家人需要看到你在哪）
    // iOS 上报前实时读取电量（battery_plus 轮询值可能不准确）
    if (Platform.isIOS) {
      try {
        final level = await _battery.batteryLevel.timeout(const Duration(seconds: 3), onTimeout: () => -1);
        final state = await _battery.batteryState.timeout(const Duration(seconds: 3), onTimeout: () => BatteryState.unknown);
        if (level >= 0) {
          _myBatteryLevel = level;
          _myCharging = state == BatteryState.charging;
        }
      } catch (_) {}
    }
    _socketService.sendLocationUpdate(
      userId: widget.currentUser.id,
      latitude: pos.latitude,
      longitude: pos.longitude,
      accuracy: pos.accuracy,
      speed: effectiveSpeed,
      batteryLevel: _myBatteryLevel,
      isCharging: _myCharging,
    );
    _lastReportedPosition = pos;

    // 逆地理解码防抖：始终请求（室内精度差也值得做，地址粗略也有参考价值）
    _geocodeDebounce?.cancel();
    _geocodeDebounce = Timer(const Duration(seconds: 2), () async {
      try {
        final result = await _apiService.reverseGeocode(pos.latitude, pos.longitude);
        final addr = (result['address'] as String?)?.isNotEmpty == true
            ? result['address'] as String
            : (result['formatted'] as String? ?? '');
        debugPrint('[Geocode] 自己的逆地理结果: addr="$addr"');
        if (addr.isNotEmpty && mounted) {
          _myAddress = addr;
          final idx = _members.indexWhere((m) => m['id'] == widget.currentUser.id);
          if (idx >= 0) {
            _members[idx]['address'] = addr;
          }
          if (_isPageVisible) setState(() {}); // 只刷新面板中的地址文本
        }
      } catch (e) {
        debugPrint('[Geocode] 异常: $e');
      }
    });

    // 更新自己的trail（使用GCJ-02坐标显示在地图上）
    // 精度 > 200m 时不更新标记位置（GPS极差时防止偏移巨大）
    // 但仍然上报位置给服务器（只是本地显示不做抖动）
    final myKey = widget.currentUser.id;
    final accuracy = pos.accuracy;
    final shouldUpdateMarker = accuracy <= 200 || forceUpdate;

    if (shouldUpdateMarker) {
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
  }

  // ==================== Socket 事件监听 ====================

  void _listenSocketEvents() {
    // 成员位置更新
    _socketSubscriptions.add(_socketService.onMemberLocation.listen((loc) {
      debugPrint('[Socket] member:location: userId=${loc.userId}, address=${loc.address}, lat=${loc.latitude}, lng=${loc.longitude}');
      void applyUpdates() {
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
          _members[idx]['is_charging'] = loc.isCharging != null ? (loc.isCharging! ? 1 : 0) : _members[idx]['is_charging'];
          _members[idx]['speed'] = loc.speed ?? _members[idx]['speed'];
          // 更新拖尾皮肤
          if (loc.trailSkin != null) {
            _members[idx]['trail_skin'] = loc.trailSkin;
          }
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
        // 精度 > 200m 时不更新标记位置（GPS极差时防止大跳变）
        // 旧阈值 20m 过严：Android 13 后台权限受限时 accuracy 常在 50-150m，
        // 导致对方收到位置但标记不移动，用户看到"不同步"
        final memberAccuracy = loc.accuracy ?? 999;
        final shouldMoveMarker = memberAccuracy <= 200;

        if (shouldMoveMarker) {
          if (_memberTrails.containsKey(loc.userId)) {
            _memberTrails[loc.userId]!.updatePosition(gcjPos, gpsSpeed: loc.speed);
            // 更新拖尾皮肤（如果对方发送了非默认值）
            if (loc.trailSkin != null && loc.trailSkin != 'default') {
              _memberTrails[loc.userId]!.skinId = loc.trailSkin!;
            }
          } else {
            _memberTrails[loc.userId] = MemberTrail(
              userId: loc.userId,
              name: name,
              color: color,
              currentPos: gcjPos,
              speed: loc.speed ?? 0,
              lastUpdate: loc.recordedAt,
              skinId: loc.trailSkin ?? 'default',
            );
          }
        }
      }
      applyUpdates(); // 必须调用！否则收到的成员位置不会更新到 UI
      // Socket成员位置更新：只刷新地图层，不触发全局 setState
      _markMapLayersDirty();
    }));

    // 成员上线
    _socketSubscriptions.add(_socketService.onMemberOnline.listen((userId) {
      if (!mounted) return;
      _onlineMembers.add(userId);
      _markMapLayersDirty();
      debugPrint('[Online] $userId 上线');
      _loadMembers();
    }));

    // 成员离线
    _socketSubscriptions.add(_socketService.onMemberOffline.listen((userId) {
      if (!mounted) return;
      _onlineMembers.remove(userId);
      _markMapLayersDirty();
      debugPrint('[Online] $userId 离线');
    }));

    // 围栏警报 → 仅系统悬浮通知
    _socketSubscriptions.add(_socketService.onGeofenceAlert.listen((data) {
      if (!mounted) return;
      final userName = data['userName'] ?? '某人';
      final fenceName = data['fenceName'] ?? '围栏';
      final userId = data['userId'] as String?;
      final avatarUrl = userId != null ? _getMemberAvatarUrl(userId) : null;
      final lat = data['latitude'] as num?;
      final lng = data['longitude'] as num?;
      NotificationService().showGeofenceAlert(
        userName: userName,
        action: data['action'] == 'entered' ? 'entered' : 'left',
        fenceName: fenceName,
        avatarUrl: avatarUrl,
        latitude: lat?.toDouble(),
        longitude: lng?.toDouble(),
      );
    }));

    // 聊天消息 → 系统悬浮通知 + 未读计数气泡 + 桌面角标
    _socketSubscriptions.add(_socketService.onChatMessage.listen((msg) {
      if (!mounted) return;
      if (msg.userId == widget.currentUser.id) return;
      final displayContent = msg.type == 'audio' ? '[语音]' : msg.content;
      NotificationService().showChatMessage(
        userName: msg.userName ?? '某人',
        content: displayContent,
        avatarUrl: msg.avatarUrl,
        circleId: msg.circleId,
      );
      // 聊天页面未打开时，增加未读计数
      if (!_isChatScreenOpen) {
        _unreadChatCount++;
        _updateAppBadge();
        if (mounted) setState(() {});
      }
    }));

    // SOS 警报 → 仅系统悬浮通知
    _socketSubscriptions.add(_socketService.onSosAlert.listen((alert) {
      if (!mounted) return;
      _vibrate();
      final avatarUrl = _getMemberAvatarUrl(alert.userId);
      NotificationService().showSosAlert(
        userName: alert.userId,
        address: alert.address,
        avatarUrl: avatarUrl,
        latitude: alert.latitude,
        longitude: alert.longitude,
      );
    }));

    // 表情炸弹
    _socketSubscriptions.add(_socketService.onEmojiBomb.listen((data) {
      if (!mounted) return;
      _triggerEmojiBomb(data['emoji'] ?? '❤️', (data['count'] ?? 10) as int);
    }));

    // 想你通知 → 仅系统悬浮通知（应用内不再重复提示）
    _socketSubscriptions.add(_socketService.onThinkingOfYou.listen((data) {
      if (!mounted) return;
      final fromName = data['fromUserName'] ?? '某人';
      final fromAvatarUrl = data['fromUserAvatarUrl'] as String?;
      NotificationService().showThinkingOfYou(fromUserName: fromName, fromUserAvatarUrl: fromAvatarUrl);
    }));

    // 存活警告 → 仅系统通知（不再弹应用内对话框）
    _socketSubscriptions.add(_socketService.onAliveWarning.listen((data) {
      if (!mounted) return;
      final userName = data['userName'] as String? ?? '某人';
      final hours = data['hours'] ?? 24;
      final userId = data['userId'] as String?;
      final avatarUrl = userId != null ? _getMemberAvatarUrl(userId) : null;
      NotificationService().showAlert(
        title: '$userName 失联警告',
        body: '已超过 $hours 小时没有更新位置，可能手机关机或信号中断',
        avatarUrl: avatarUrl,
      );
    }));

    // 碰撞警报 → 仅系统通知 + 地图定位（不再弹应用内对话框）
    _socketSubscriptions.add(_socketService.onCollisionAlert.listen((data) {
      if (!mounted) return;
      _vibrate();
      final type = data['type'] as String? ?? 'high_speed';
      final userName = data['userName'] ?? '某人';
      final title = type == 'hard_brake' ? '紧急刹车警报！' : '高速行驶警报！';
      final desc = type == 'hard_brake'
          ? '$userName 可能发生了急刹车'
          : '$userName 速度异常';
      // 定位到事发点
      if (data['latitude'] != null && data['longitude'] != null) {
        _mapController.move(
          _wgs84ToGcj02(
            (data['latitude'] as num).toDouble(),
            (data['longitude'] as num).toDouble(),
          ), 16,
        );
      }
      NotificationService().showAlert(
        title: title,
        body: desc,
      );
    }));

    // 行程报告 → 仅系统通知
    _socketSubscriptions.add(_socketService.onTripReport.listen((data) {
      if (!mounted) return;
      final userName = data['userName'] ?? '某人';
      final action = data['action'] == 'left' ? '离开了' : '到达了';
      final address = data['address'] ?? '';
      final duration = data['duration'] ?? 0;
      NotificationService().showAlert(
        title: '$userName $action$address',
        body: '停留了$duration分钟',
      );
    }));

    // 成员加入圈子 → 仅系统通知 + 刷新数据
    _socketSubscriptions.add(_socketService.onMemberJoined.listen((data) {
      if (!mounted) return;
      _loadMembers();
      _loadCircles();
      final userName = data['userName'] ?? '新成员';
      NotificationService().showAlert(
        title: '$userName 加入了圈子',
        body: '欢迎新成员',
      );
    }));

    // 低电量 → 仅系统通知
    _socketSubscriptions.add(_socketService.onLowBattery.listen((data) {
      if (!mounted) return;
      final userName = data['userName'] ?? '某人';
      final batteryLevel = data['batteryLevel'] ?? 0;
      final userId = data['userId'] as String?;
      final avatarUrl = userId != null ? _getMemberAvatarUrl(userId) : null;
      NotificationService().showAlert(
        title: '$userName 电量低',
        body: '电量仅剩 $batteryLevel%',
        avatarUrl: avatarUrl,
      );
    }));

    // 到家/离家 → 仅系统通知
    _socketSubscriptions.add(_socketService.onHomeStatus.listen((data) {
      if (!mounted) return;
      final action = data['action'] as String? ?? '';
      final userName = data['userName'] as String? ?? '某人';
      final userId = data['userId'] as String?;
      final avatarUrl = userId != null ? _getMemberAvatarUrl(userId) : null;
      if (action == 'arrived') {
        NotificationService().showAlert(
          title: userName,
          body: '已到家',
          avatarUrl: avatarUrl,
        );
      } else if (action == 'left') {
        NotificationService().showAlert(
          title: userName,
          body: '已离家',
          avatarUrl: avatarUrl,
        );
      }
    }));

    // 多设备互踢：收到强制登出通知
    _socketSubscriptions.add(_socketService.onForceLogout.listen((data) async {
      if (!mounted) return;
      final reason = data['reason'] as String? ?? '账号已在其他设备登录';
      // 1. 断开 Socket 连接
      _socketService.disconnect();
      // 2. 停止位置追踪
      _positionStream?.cancel();
      _periodicSendTimer?.cancel();
      // 3. 清除本地存储的登录信息
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('familymap_user');
      // 4. 显示提示并跳转到登录页
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Row(children: [
              Icon(Icons.logout, color: Colors.red, size: 28),
              SizedBox(width: 8),
              Text('被迫下线'),
            ]),
            content: Text(reason),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx); // 关闭对话框
                  // 跳转到登录页（清空整个导航栈）
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => SplashScreen(
                      darkMode: _isDark,
                      onDarkModeChanged: widget.onDarkModeChanged,
                    )),
                    (route) => false,
                  );
                },
                child: const Text('重新登录'),
              ),
            ],
          ),
        );
      }
    }));

    // Socket 认证失败（token 被其他设备登录踢掉）：静默跳转登录页
    _socketSubscriptions.add(_socketService.onAuthFailed.listen((_) async {
      if (!mounted) return;
      _socketService.disconnect();
      _positionStream?.cancel();
      _periodicSendTimer?.cancel();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('familymap_user');
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => SplashScreen(
            darkMode: _isDark,
            onDarkModeChanged: widget.onDarkModeChanged,
          )),
          (route) => false,
        );
      }
    }));
  }

  // ==================== 数据加载 ====================

  Future<void> _loadCircles({bool fromCache = false}) async {
    try {
      if (fromCache) {
        // 从本地缓存加载圈子列表，实现启动秒展示
        final cached = await LocalCacheService.instance.getCircles();
        if (cached != null && cached.isNotEmpty && mounted) {
          final circles = cached.map((c) => Circle.fromJson(c)).toList();
          setState(() => _circles = circles);
          if (_currentCircle == null) {
            await _selectCircle(circles.first, loadMembersFromCache: true);
          }
        }
        return;
      }
      final circles = await _apiService.getUserCircles(widget.currentUser.id);
      debugPrint('[Circles] 用户 ${widget.currentUser.id} 有 ${circles.length} 个圈子');
      setState(() => _circles = circles);
      // 保存到本地缓存
      LocalCacheService.instance.saveCircles(circles.map((c) => c.toJson()).toList());
      if (circles.isNotEmpty && _currentCircle == null) {
        debugPrint('[Circles] 自动选择圈子: ${circles.first.name} (${circles.first.id})');
        await _selectCircle(circles.first);
      } else if (circles.isNotEmpty && _currentCircle != null) {
        // 已有选中的圈子，刷新围栏
        await _loadGeofences();
      } else if (circles.isEmpty) {
        debugPrint('[Circles] 没有圈子，需要创建或加入');
      }
    } catch (e) {
      debugPrint('加载圈子失败: $e');
    }
  }

  Future<void> _selectCircle(Circle circle, {bool loadMembersFromCache = false}) async {
    setState(() => _currentCircle = circle);
    await _loadMembers(fromCache: loadMembersFromCache);
    // 无论是否缓存路径，都尝试加载围栏（缓存路径从缓存读取，非缓存路径从API刷新）
    if (loadMembersFromCache) {
      // 缓存路径：只从本地缓存加载围栏，不发网络请求
      final cached = await LocalCacheService.instance.getGeofences(circle.id);
      if (cached != null) {
        _geofences = cached.map((m) => Geofence.fromJson(m)).toList();
        _markMapLayersDirty();
        if (mounted) setState(() {});
      }
    } else {
      await _loadGeofences();
    }
    _startLocationSharing();
  }

  Future<void> _loadMembers({bool fromCache = false}) async {
    if (_currentCircle == null) return;
    try {
      if (fromCache) {
        // 从本地缓存加载成员列表，启动秒展示
        final cached = await LocalCacheService.instance.getMembers();
        if (cached != null && cached.isNotEmpty && mounted) {
          _members = cached;
          _markMapLayersDirty();
          setState(() {});
          _restoreMembersToTrails(); // 恢复成员标记到地图
        }
        return;
      }
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

          // 保留 socket 实时推送的电量数据（比服务端 DB 更新）
          final localBattery = existing['battery_level'] as int?;
          final serverBattery = m['battery_level'] as int?;
          if (localBattery != null && (serverBattery == null || localBattery != serverBattery)) {
            // 如果本地有更新的电量值，优先保留（socket 比 HTTP API 更实时）
            m['battery_level'] = localBattery;
            m['is_charging'] = existing['is_charging'];
          }
        }

        // 如果是自己且有缓存的 _myAddress，优先使用
        if (id == widget.currentUser.id && _myAddress.isNotEmpty) {
          m['address'] = _myAddress;
        }
      }

      _members = members;
      _markMapLayersDirty(); // 刷新地图层（幽灵圈+Marker）
      if (mounted && _isPageVisible) setState(() {}); // 刷新面板列表

      // 成员列表加载后，立即用本机电池状态覆盖自己的数据（解决启动时充电状态延迟问题）
      _syncSelfBatteryToMembers();

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
              skinId: id == widget.currentUser.id ? _myTrailSkin : (m['trail_skin'] as String? ?? 'default'),
            );
          }
          // 自己的速度由 GPS 实时更新（_effectiveSpeed），不能被服务端旧值覆盖
          if (m['speed'] != null && id != widget.currentUser.id) {
            _memberTrails[id]!.speed = (m['speed'] as num).toDouble();
          }
        }
      }
    } catch (e) {
      debugPrint('加载成员失败: $e');
    }
    // 缓存成员列表到本地
    LocalCacheService.instance.saveMembers(_members);
  }

  /// 从缓存恢复时：将成员列表数据恢复到地图标记中
  void _restoreMembersToTrails() {
    for (final m in _members) {
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
            skinId: id == widget.currentUser.id ? _myTrailSkin : (m['trail_skin'] as String? ?? 'default'),
          );
        }
        if (m['speed'] != null && id != widget.currentUser.id) {
          _memberTrails[id]!.speed = (m['speed'] as num).toDouble();
        }
      }
    }
  }

  /// 为单个成员获取逆地理地址
  Future<void> _fetchMemberAddress(Map<String, dynamic> member) async {
    try {
      final lat = (member['latitude'] as num).toDouble();
      final lng = (member['longitude'] as num).toDouble();
      // 先从缓存获取
      final cached = await LocalCacheService.instance.getGeocodeResult(lat, lng);
      if (cached != null && cached.isNotEmpty) {
        if (mounted) {
          setState(() {
            final idx = _members.indexWhere((m) => m['id'] == member['id']);
            if (idx >= 0) _members[idx]['address'] = cached;
          });
        }
        return;
      }
      debugPrint('[FetchAddr] 为成员 ${member['name']} 获取地址: lat=$lat, lng=$lng');
      final result = await _apiService.reverseGeocode(lat, lng);
      // 优先用完整 address，formatted 只有街道名
      final addr = (result['address'] as String?)?.isNotEmpty == true
          ? result['address'] as String
          : (result['formatted'] as String? ?? '');
      debugPrint('[FetchAddr] 成员 ${member['name']} 地址结果: "$addr"');
      if (addr.isNotEmpty && mounted) {
        // 保存到缓存
        await LocalCacheService.instance.saveGeocodeResult(lat, lng, addr);
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
      // 先从缓存加载
      final cached = await LocalCacheService.instance.getGeofences(_currentCircle!.id);
      if (cached != null) {
        _geofences = cached.map((m) => Geofence.fromJson(m)).toList();
        _markMapLayersDirty();
        if (mounted) setState(() {});
      }
      // 后台刷新
      final fences = await _apiService.getGeofences(_currentCircle!.id);
      debugPrint('[围栏] 加载了 ${fences.length} 个围栏（圈子: ${_currentCircle!.name}）');
      _geofences = fences;
      // 保存到缓存
      await LocalCacheService.instance.saveGeofences(_currentCircle!.id, fences.map((f) => f.toJson()).toList());
      _markMapLayersDirty();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[围栏] 加载失败: $e');
    }
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
                RepaintBoundary(child: _buildHeader()),
                Expanded(child: RepaintBoundary(child: _buildMap())),
                RepaintBoundary(child: _buildBottomPanel()),
              ],
            ),
            // GPS调试浮窗
            if (_gpsDebugEnabled) _buildGpsDebugOverlay(),
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
          // 聊天（带未读消息红色气泡）
          SizedBox(
            width: 40,
            height: 40,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  icon: const Icon(Icons.chat_bubble_outline, size: 20),
                  onPressed: _currentCircle != null ? () => _openChat() : null,
                  tooltip: '群聊',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                ),
                if (_unreadChatCount > 0)
                  Positioned(
                    right: 2,
                    top: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      child: Text(
                        _unreadChatCount > 99 ? '99+' : '$_unreadChatCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
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
        // FlutterMap + 动态层：只在 _mapLayerVersion 变化时整体重建
        // 其他 setState（面板拖拽、Tab切换等）不会触发地图层重建
        ValueListenableBuilder<int>(
          valueListenable: _mapLayerVersion,
          builder: (context, _, __) => FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: LatLng(39.9042, 116.4074),
            initialZoom: 13,
            maxZoom: 19,
            minZoom: 3,
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
            onLongPress: (position, point) {
              if (_isPlacingGeofence) return;
              _geofencePinPos = point;
              _isPlacingGeofence = true;
              _markMapLayersDirty();
              _showGeofenceCreateDialog(point);
            },
          ),
          children: [
            TileLayer(
              key: ValueKey(_isDark),
              tileProvider: _tileProvider,
              urlTemplate: 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
              subdomains: const ['1', '2', '3', '4'],
              maxZoom: 19,
              maxNativeZoom: 18,
              minNativeZoom: 3,
            ),
            if (_showHeatmap && _heatmapPoints.isNotEmpty)
              CircleLayer(
                circles: _heatmapPoints.map((p) {
                  final intensity = (p['intensity'] as num).toDouble();
                  final color = Color.lerp(
                    const Color(0xFF00BCD4),
                    const Color(0xFFFF1744),
                    intensity,
                  )!.withOpacity(0.3 + intensity * 0.4);
                  return CircleMarker(
                    point: _wgs84ToGcj02((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()),
                    radius: 50 + intensity * 100,
                    useRadiusInMeter: true,
                    color: color,
                    borderColor: Colors.transparent,
                    borderStrokeWidth: 0,
                  );
                }).toList(),
              ),
            // 世界迷雾遮罩层：已探索区域透明，未探索区域半透明遮罩
            if (_showWorldFog && _worldFogGrids.isNotEmpty)
              PolygonLayer(
                polygons: [
                  Polygon(
                    // 外边界覆盖全球
                    points: [
                      const LatLng(85, -180),
                      const LatLng(85, 180),
                      const LatLng(-85, 180),
                      const LatLng(-85, -180),
                    ],
                    // 已探索网格作为“洞”露出
                    holePointsList: _worldFogGrids.map((grid) {
                      final center = _wgs84ToGcj02(grid.lat, grid.lng);
                      const half = 0.05; // 半格宽（0.1度/2）
                      return [
                        LatLng(center.latitude + half, center.longitude - half),
                        LatLng(center.latitude + half, center.longitude + half),
                        LatLng(center.latitude - half, center.longitude + half),
                        LatLng(center.latitude - half, center.longitude - half),
                      ];
                    }).toList(),
                    color: (_isDark ? Colors.black : Colors.grey).withOpacity(0.55),
                    borderColor: Colors.transparent,
                    borderStrokeWidth: 0,
                  ),
                ],
              ),
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
            CircleLayer(
              circles: _members
                .where((m) => m['ghost_mode'] == 'blur' && m['latitude'] != null)
                .map((m) => CircleMarker(
                  point: _wgs84ToGcj02(
                    (m['latitude'] as num).toDouble(),
                    (m['longitude'] as num).toDouble(),
                  ),
                  radius: 250,
                  useRadiusInMeter: true,
                  color: const Color(0xFF6366F1).withOpacity(0.12),
                  borderColor: const Color(0xFF6366F1).withOpacity(0.4),
                  borderStrokeWidth: 1.5,
                )).toList(),
            ),
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
            TrailParticleLayer(
              mapController: _mapController,
              memberTrails: _memberTrails,
            ),
            MarkerLayer(
              markers: _buildClusteredMarkers(),
            ),
          ],
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
        // 缩放控件（RepaintBoundary 隔离，避免地图缩放时按钮闪烁）
        Positioned(
          right: 8,
          top: 8,
          child: RepaintBoundary(child: Column(
            children: [
              _zoomButton(Icons.add, () => _mapController.move(_mapController.camera.center, _mapController.camera.zoom + 1), tooltip: '放大'),
              const SizedBox(height: 4),
              _zoomButton(Icons.remove, () => _mapController.move(_mapController.camera.center, _mapController.camera.zoom - 1), tooltip: '缩小'),
              const SizedBox(height: 8),
              // 4.5 热力图切换按钮（显示最近7天停留密度）
              _zoomButton(
                _showHeatmap ? Icons.layers_clear : Icons.layers,
                _toggleHeatmap,
                color: _showHeatmap ? Colors.blue : null,
                tooltip: _showHeatmap ? '关闭停留热力图' : '显示停留热力图',
              ),
              const SizedBox(height: 8),
            ],
          )),
        ),
        // 热力图提示标签
        if (_showHeatmap)
          Positioned(
            left: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blue.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue),
              ),
              child: const Row(children: [
                Icon(Icons.layers, color: Colors.blue, size: 16),
                SizedBox(width: 4),
                Text('停留热力图（近7天）', style: TextStyle(color: Colors.blue, fontSize: 12, fontWeight: FontWeight.w500), textScaleFactor: 1.0),
              ]),
            ),
          ),
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
                Text('位置暂停共享', style: TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.w500), textScaleFactor: 1.0),
              ]),
            ),
          ),
        // 世界迷雾提示标签
        if (_showWorldFog)
          Positioned(
            left: 8,
            top: _showHeatmap ? 38 : (_userSettings?.sharePaused == true ? 38 : 8),
            child: GestureDetector(
              onTap: () { setState(() => _showWorldFog = false); _markMapLayersDirty(); },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF8B5CF6)),
                ),
                child: const Row(children: [
                  Icon(Icons.public, color: Color(0xFF8B5CF6), size: 16),
                  SizedBox(width: 4),
                  Text('世界迷雾', style: TextStyle(color: Color(0xFF8B5CF6), fontSize: 12, fontWeight: FontWeight.w500), textScaleFactor: 1.0),
                  SizedBox(width: 4),
                  Icon(Icons.close, color: Color(0xFF8B5CF6), size: 14),
                ]),
              ),
            ),
          ),
      ],
    );
  }

  Widget _zoomButton(IconData icon, VoidCallback onPressed, {Color? color, String? tooltip}) {
    return Container(
      decoration: BoxDecoration(
        color: color ?? Colors.white,
        borderRadius: BorderRadius.circular(4),
        boxShadow: const [BoxShadow(color: Color(0x1F000000), blurRadius: 4)],
      ),
      child: IconButton(
        icon: Icon(icon, size: 18, color: color != null ? Colors.white : null),
        onPressed: onPressed,
        padding: const EdgeInsets.all(4),
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        tooltip: tooltip,
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
        _panelHeightNotifier.value = (_dragStartHeight + dy).clamp(_panelPeek, _panelFull);
      },
      onVerticalDragEnd: (_) {
        // 松手时吸附到最近档位
        _snapPanel();
      },
      // ValueListenableBuilder: 拖拽时只重建面板容器，不触发整个 MapScreen setState
      child: ValueListenableBuilder<double>(
        valueListenable: _panelHeightNotifier,
        builder: (context, panelH, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutBack, // 弹性缓动
        height: panelH,
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
            // Tab 栏 + 刷新按钮
            Row(
              children: [
                ...['成员', '圈子', '围栏', '轨迹']
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
                              textScaleFactor: 1.0,
                            ),
                          ),
                        ),
                      ))
                  .toList(),
                // 手动刷新按钮
                GestureDetector(
                  onTap: () async {
                    await _loadCircles();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已刷新'), duration: Duration(seconds: 1)),
                      );
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Icon(Icons.refresh, size: 20,
                      color: _isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                  ),
                ),
              ],
            ),
            // 内容
            Expanded(child: _buildTabContent()),
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildTabContent() {
    // IndexedStack：4个Tab同时保持存活，切换不销毁/重建
    return IndexedStack(
      index: _currentTab,
      children: [
        KeyedSubtree(key: const ValueKey('members'), child: _buildMembersList()),
        KeyedSubtree(key: const ValueKey('circles'), child: _buildCirclesList()),
        KeyedSubtree(key: const ValueKey('fences'), child: _buildFencesList()),
        KeyedSubtree(key: const ValueKey('history'), child: _buildHistoryTab()),
      ],
    );
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

    return RefreshIndicator(
      onRefresh: () async {
        await _loadCircles();
      },
      color: const Color(0xFF4F46E5),
      child: SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: List.generate(_members.length, (i) {
        final m = _members[i];
        final id = m['id'] as String;
        final name = m['name'] as String;
        final isMe = id == widget.currentUser.id;
        final trail = _memberTrails[id];
        final color = _parseColor(m['avatar_color'] ?? '#4F46E5');
        // 自己的电量直接用本机实时值，避免 _loadMembers 全量替换时的旧数据覆盖
        final battery = isMe ? _myBatteryLevel : (m['battery_level'] as int?);
        final charging = isMe ? _myCharging : ((m['is_charging'] ?? 0) == 1);
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
            _selectedMemberId = id;
            _markMapLayersDirty(); // z-order 变化 → 刷新地图标记
            setState(() {}); // 高亮面板卡片
            if (trail != null) {
              _mapController.move(trail.currentPos, 16);
              // 同时弹出成员详情底部弹窗（与点击地图标记一致）
              _showMemberDetail(trail, m);
            }
          },
          child: _buildMemberCardContent(
            name: name, isMe: isMe, color: color,
            avatarColorHex: m['avatar_color'] as String? ?? '#4F46E5',
            avatarUrl: m['avatar_url'] as String?,
            mood: mood,
            isSleeping: isSleeping, nicknameColor: nicknameColor,
            ghostMode: m['ghost_mode'] as String?,
            trail: trail, battery: battery, charging: charging,
            lastTime: lastTime, address: address,
            stayAddress: stayAddress, stayMinutes: stayMinutes,
          ),
        );
      }),
      ),
    ),
    );
  }

  /// 选中的成员ID（用于高亮边框）
  String? _selectedMemberId;

  /// 构建成员卡片内容（抽出为独立方法以便复用）
  Widget _buildMemberCardContent({
    required String name, required bool isMe, required Color color,
    required String avatarColorHex,
    String? avatarUrl,
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
              AvatarWidget(
                name: name,
                avatarColor: avatarColorHex,
                avatarUrl: isMe ? (widget.currentUser.avatarUrl ?? avatarUrl) : avatarUrl,
                size: 40,
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
                        child: const Text('已隐身', style: TextStyle(fontSize: 10, color: Colors.white70), textScaleFactor: 1.0),
                      ),
                    ] else if (ghostMode == 'blur') ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6366F1).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('模糊位置', style: TextStyle(fontSize: 10, color: Color(0xFF6366F1)), textScaleFactor: 1.0),
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
                        child: Text(mood!, style: TextStyle(fontSize: 10, color: _isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)), textScaleFactor: 1.0, overflow: TextOverflow.ellipsis, maxLines: 1),
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.location_on, size: 11, color: Color(0xFF94A3B8)),
                      const SizedBox(width: 2),
                      Expanded(child: Text(
                        stayAddress,
                        style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                        maxLines: 2,
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.location_on, size: 11, color: Color(0xFF94A3B8)),
                      const SizedBox(width: 2),
                      Expanded(child: Text(
                        address,
                        style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                        maxLines: 2,
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
        IOSBatteryIcon(level: level, charging: charging, size: 12),
        const SizedBox(width: 2),
        Text(
          '$level%',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: color,
          ),
          textScaleFactor: 1.0,
        ),
        if (charging) ...[
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFF34C759).withOpacity(0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt, size: 8, color: Color(0xFF34C759)),
                SizedBox(width: 2),
                Text('充电中', style: TextStyle(fontSize: 9, color: Color(0xFF34C759), fontWeight: FontWeight.w600), textScaleFactor: 1.0),
              ],
            ),
          ),
        ],
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
                Text('低电量', style: TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.w600), textScaleFactor: 1.0),
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
              onTap: () {
                _isPageVisible = false;
                Navigator.push(context, _fastRoute(
                  TimelineScreen(currentUser: widget.currentUser, apiService: _apiService),
                )).then((_) { _isPageVisible = true; if (mounted) setState(() {}); });
              },
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
              onTap: () {
                _isPageVisible = false;
                Navigator.push(context, _fastRoute(
                  FootprintScreen(currentUser: widget.currentUser, apiService: _apiService),
                )).then((_) { _isPageVisible = true; if (mounted) setState(() {}); });
              },
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

  /// 快速页面转场：保留 iOS 左滑返回手势
  Route<T> _fastRoute<T>(Widget page) {
    return MaterialPageRoute<T>(builder: (_) => page);
  }

  /// 通知点击回调（微信风格跳转）
  void _onNotificationTapped(String type, Map<String, dynamic> data) {
    if (!mounted) return;

    switch (type) {
      case 'chat':
        // 点击聊天通知 → 跳转到对应圈子聊天页，清零未读
        _unreadChatCount = 0;
        _updateAppBadge();
        final circleId = data['circleId'] as String?;
        if (circleId == null) return;
        final circle = _circles.where((c) => c.id == circleId).firstOrNull;
        if (circle == null) return;
        // 关闭可能打开的其他页面，回到地图后再 push 聊天
        Navigator.of(context).popUntil((route) => route.isFirst);
        _isPageVisible = false;
        _isChatScreenOpen = true;
        Navigator.push(context, _fastRoute(
          ChatScreen(
            circle: circle,
            currentUser: widget.currentUser,
            socketService: _socketService,
            apiService: _apiService,
          ),
        )).then((_) {
          _isPageVisible = true;
          _isChatScreenOpen = false;
          if (mounted) setState(() {});
        });
        break;

      case 'sos':
      case 'geofence':
        // 点击 SOS / 围栏通知 → 定位到地图对应位置
        final lat = data['latitude'] as num?;
        final lng = data['longitude'] as num?;
        if (lat != null && lng != null) {
          Navigator.of(context).popUntil((route) => route.isFirst);
          _mapController.move(_wgs84ToGcj02(lat.toDouble(), lng.toDouble()), 16);
        }
        break;

      default:
        // 其他通知 → 回到地图主页
        Navigator.of(context).popUntil((route) => route.isFirst);
        break;
    }
  }

  /// 更新桌面图标角标数字
  void _updateAppBadge() {
    try {
      if (_unreadChatCount > 0) {
        FlutterAppBadger.updateBadgeCount(_unreadChatCount);
      } else {
        FlutterAppBadger.removeBadge();
      }
    } catch (e) {
      // 部分设备/启动器不支持角标，忽略即可
    }
  }

  void _openChat() {
    if (_currentCircle == null) return;
    _isPageVisible = false;
    _isChatScreenOpen = true; // 标记聊天页面已打开
    // 打开即清零未读
    _unreadChatCount = 0;
    _updateAppBadge();
    Navigator.push(context, _fastRoute(
      ChatScreen(
        circle: _currentCircle!,
        currentUser: widget.currentUser,
        socketService: _socketService,
        apiService: _apiService,
      ),
    )).then((_) {
      _isPageVisible = true;
      _isChatScreenOpen = false; // 聊天页面已关闭
      if (mounted) setState(() {});
    });
  }

  void _openSettings() {
    _isPageVisible = false;
    Navigator.push(context, _fastRoute(
      SettingsScreen(
        currentUser: widget.currentUser,
        apiService: _apiService,
        darkMode: widget.darkMode,
        onDarkModeChanged: widget.onDarkModeChanged,
      ),
    )).then((_) {
      _isPageVisible = true;
      _loadSettings();
      _loadGpsDebugFlag();
      // 刷新成员列表以同步头像变更
      _loadMembers();
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
  /// 从 stay_started_at 实时计算停留时长，避免用服务端旧的 stay_minutes
  int? _computeStayMinutes(Map<String, dynamic> member) {
    final stayStartedAt = member['stay_started_at'] as String?;
    if (stayStartedAt != null) {
      final started = DateTime.tryParse(stayStartedAt);
      if (started != null) return DateTime.now().difference(started).inMinutes;
    }
    return member['stay_minutes'] as int?;
  }

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

    // 2. 对同位置组：环形/花瓣状分布（仿 Jagat/Life360 风格）
    //    中心放一个成员，其余成员围绕中心均匀散开
    final Map<String, LatLng> adjustedPositions = {};

    for (final group in groups) {
      if (group.length == 1) {
        adjustedPositions[trails[group[0]].userId] = trails[group[0]].currentPos;
      } else {
        // 中心点：优先用"自己"的位置，否则用第一个成员
        final myIndex = group.indexWhere((i) => trails[i].userId == widget.currentUser.id);
        final centerIdx = myIndex >= 0 ? group[myIndex] : group[0];
        final centerPos = trails[centerIdx].currentPos;

        // 环形偏移半径：人数越多半径越大，但最小保证头像露出
        // stackOffset ~0.00012° ≈ 13m，2-3人用1倍，4-5人用1.5倍，6+用2倍
        final radiusMultiplier = group.length <= 3 ? 1.0 : (group.length <= 5 ? 1.5 : 2.0);
        final radius = stackOffset * radiusMultiplier;

        // 将非中心成员均匀分布在圆周上
        final nonCenterIndices = <int>[];
        for (int idx = 0; idx < group.length; idx++) {
          if (group[idx] != centerIdx) {
            nonCenterIndices.add(group[idx]);
          }
        }

        // 中心成员
        adjustedPositions[trails[centerIdx].userId] = centerPos;

        // 周围成员：等角度分布，起始角度从正上方(-90°)开始顺时针
        final count = nonCenterIndices.length;
        for (int i = 0; i < count; i++) {
          final trailIdx = nonCenterIndices[i];
          final angle = (-90 + i * (360 / count)) * pi / 180;
          final offsetLat = centerPos.latitude + radius * cos(angle);
          final offsetLng = centerPos.longitude + radius * sin(angle);
          adjustedPositions[trails[trailIdx].userId] = LatLng(offsetLat, offsetLng);
        }
      }
    }

    // 3. 生成 Marker 列表
    // 关键：自己要最后添加（Flutter MarkerLayer 后添加的在上层）
    // 选中的成员也要靠后（仅次于自己），确保点击成员列表后该成员不被遮挡
    final sortedTrails = List<MemberTrail>.from(trails)..sort((a, b) {
      // 优先级：自己 > 选中成员 > 其他人
      final aIsMe = a.userId == widget.currentUser.id ? 2 : 0;
      final bIsMe = b.userId == widget.currentUser.id ? 2 : 0;
      final aIsSelected = a.userId == _selectedMemberId ? 1 : 0;
      final bIsSelected = b.userId == _selectedMemberId ? 1 : 0;
      return (aIsMe + aIsSelected) - (bIsMe + bIsSelected);
    });

    int markerIndex = 0;
    return sortedTrails.map((trail) {
      final isMe = trail.userId == widget.currentUser.id;
      final member = _members.firstWhere(
        (m) => m['id'] == trail.userId, orElse: () => <String, dynamic>{},
      );
      final isOnline = _onlineMembers.contains(trail.userId);
      final pos = adjustedPositions[trail.userId] ?? trail.displayPos;
      // 自己直接用本机电池数据，好友用 member 里的
      final battery = isMe ? _myBatteryLevel : (member['battery_level'] as int?);
      final charging = isMe ? _myCharging : ((member['is_charging'] ?? 0) == 1);
      return Marker(
        point: pos,
        width: 130,
        height: 140,
        // alignment 对准头像中心：left=65(130/2), top=60(速度标签20+在线标签18+头像半径22)
        alignment: Marker.computePixelAlignment(width: 130, height: 140, left: 65, top: 60),
        // RepaintBoundary：每个标记独立重绘，一个标记变化不会影响其他
        child: RepaintBoundary(child: MemberMarker(
          name: trail.name,
          color: trail.color,
          avatarUrl: isMe ? (widget.currentUser.avatarUrl ?? member['avatar_url'] as String?) : member['avatar_url'] as String?,
          isMe: isMe,
          isOnline: isOnline,
          isMoving: trail.isMoving,
          heading: trail.heading,
          speedMs: trail.speed,
          movementType: trail.movementType,
          batteryLevel: battery,
          isCharging: charging,
          stayMinutes: _computeStayMinutes(member),
          onTap: () => _showMemberDetail(trail, member),
          index: markerIndex++,
        )),
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
                _buildDetailAvatar(trail, member),
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
                      targetUserId: member['id'] as String?,  // 指定目标用户
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
        speed: _isCurrentlyMoving ? _ewmaSpeed : 1.0, // 默认步行速度
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
        trail.currentPos.latitude,
        trail.currentPos.longitude,
        durationMinutes: 24 * 60, // 24小时有效
      );
      final url = result['url'] as String? ?? '${AppConfig.shareBaseUrl}/share/${result['token']}';
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) {
        final shareResult = await Share.share('查看我的位置: $url', subject: '${widget.currentUser.name}的位置分享');
        if (mounted && shareResult.status == ShareResultStatus.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('链接已复制到剪贴板'), duration: Duration(seconds: 2)),
          );
        }
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
        trail.currentPos.latitude,
        trail.currentPos.longitude,
        durationMinutes: 4 * 60, // 行程分享4小时有效
        trackMode: true, // 行程模式：对方能看到实时移动位置
      );
      final url = result['url'] as String? ?? '${AppConfig.shareBaseUrl}/share/${result['token']}';
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) {
        final shareResult = await Share.share('实时追踪我的行程: $url', subject: '${widget.currentUser.name}的行程分享');
        if (mounted && shareResult.status == ShareResultStatus.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('链接已复制到剪贴板'), duration: Duration(seconds: 2)),
          );
        }
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
    final url = await _apiService.getGpxExportUrl(trail.userId, date: dateStr);
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

  /// 成员详情弹窗中的头像（支持预设 + 生肖 + 自定义图片）
  Widget _buildDetailAvatar(MemberTrail trail, Map<String, dynamic> member) {
    final url = member['avatar_url'] as String?;
    final isMe = member['id'] == widget.currentUser.id;
    return AvatarWidget(
      name: trail.name,
      avatarColor: '#${trail.color.value.toRadixString(16).substring(2).toUpperCase()}',
      avatarUrl: isMe ? (widget.currentUser.avatarUrl ?? url) : url,
      size: 56,
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
            _markMapLayersDirty();
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
                );
                setState(() { _geofencePinPos = null; _isPlacingGeofence = false; });
                _markMapLayersDirty();
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
    _markMapLayersDirty();
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
    // 如果迷雾已开，切换关闭
    if (_showWorldFog) {
      setState(() => _showWorldFog = false);
      _markMapLayersDirty();
      return;
    }
    try {
      final stats = await _apiService.getWorldStats(widget.currentUser.id);
      if (!mounted) return;
      // 开启迷雾遮罩 + 缓存网格数据
      setState(() {
        _worldFogGrids = stats.grids;
        _showWorldFog = true;
      });
      _markMapLayersDirty();
      // 同时弹出统计信息
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
              const SizedBox(height: 8),
              const Text('地图上的迷雾已揭开，再次点击可关闭', style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
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
    if (minutes <= 0) return '0分';
    final d = minutes ~/ (24 * 60);
    final h = (minutes % (24 * 60)) ~/ 60;
    final m = minutes % 60;
    final parts = <String>[];
    if (d > 0) parts.add('${d}天');
    if (h > 0) parts.add('${h}时');
    if (m > 0) parts.add('${m}分');
    if (parts.isEmpty) parts.add('${minutes}分');
    return parts.join('');
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
