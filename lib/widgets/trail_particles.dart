import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

// ==================== Jagat 风格轨迹拖尾 ====================
// 核心思路：记录移动轨迹点，绘制沿路径的渐变拖尾带
// - 速度快时拖尾长，尺寸恒定，跟随方向变化
// - 静止时拖尾渐消
// - 用8色梯度：头部亮色→尾部暗色
//
// 性能优化：
// - 无拖尾时自动停止动画控制器（不再 60fps 空转）
// - shouldRepaint 比较轨迹哈希，避免无变化时重绘
// - 动画帧率从 60fps 降到 30fps（肉眼几乎无差别，CPU 省一半）

// ==================== 轨迹皮肤颜色梯度 ====================

// 默认：翠绿 → 黄 → 橘 → 玫红
const List<Color> kDefaultGradient = [
  Color(0xFF00BF6A), Color(0xFF64D232), Color(0xFFB4E61E), Color(0xFFFFDC00),
  Color(0xFFFFA000), Color(0xFFFF5028), Color(0xFFC81E50), Color(0xFF8C1478),
];

// 火焰：深红 → 亮橙 → 亮黄 → 白芯
const List<Color> kFireGradient = [
  Color(0xFF8B0000), Color(0xFFCC2200), Color(0xFFFF4400), Color(0xFFFF6600),
  Color(0xFFFF9900), Color(0xFFFFBB00), Color(0xFFFFDD44), Color(0xFFFFF5CC),
];

// 冰雪：深海蓝 → 天蓝 → 冰蓝 → 白
const List<Color> kIceGradient = [
  Color(0xFF0A1628), Color(0xFF0D3B66), Color(0xFF1A759F), Color(0xFF34A0A4),
  Color(0xFF52D3D8), Color(0xFF76E4F7), Color(0xFFB8F2FF), Color(0xFFE8FBFF),
];

// 彩虹：红 → 橙 → 黄 → 绿 → 蓝 → 紫
const List<Color> kRainbowGradient = [
  Color(0xFFFF0000), Color(0xFFFF7700), Color(0xFFFFDD00), Color(0xFF00CC44),
  Color(0xFF0088FF), Color(0xFF4400FF), Color(0xFF8800CC), Color(0xFFCC00FF),
];

// 星河：深紫 → 靛蓝 → 粉紫 → 银白星光
const List<Color> kGalaxyGradient = [
  Color(0xFF0D0221), Color(0xFF150438), Color(0xFF2A0845), Color(0xFF551373),
  Color(0xFF8B2FC9), Color(0xFFC850C0), Color(0xFFFFCC70), Color(0xFFFFFBF0),
];

// 粒子：翠绿 → 青绿 → 黄绿 → 亮黄 → 橘橙 → 红橙 → 玫红 → 深紫（速度颜色梯度）
const List<Color> kParticleGradient = [
  Color(0xFF00BF6A), Color(0xFF64D232), Color(0xFFB4E61E), Color(0xFFFFDC00),
  Color(0xFFFFA000), Color(0xFFFF5028), Color(0xFFC81E50), Color(0xFF8C1478),
];

/// 根据皮肤 ID 获取对应梯度
List<Color> getTrailGradient(String skinId) {
  switch (skinId) {
    case 'fire':      return kFireGradient;
    case 'ice':       return kIceGradient;
    case 'rainbow':   return kRainbowGradient;
    case 'galaxy':    return kGalaxyGradient;
    case 'particle':  return kParticleGradient;
    default:          return kDefaultGradient;
  }
}

/// 根据 t(0~1) 在梯度中插值获取颜色
Color lerpTrailColor(double t, {List<Color>? gradient}) {
  final colors = gradient ?? kDefaultGradient;
  final idx = t * (colors.length - 1);
  final i = idx.floor().clamp(0, colors.length - 2);
  final f = idx - i;
  return Color.lerp(colors[i], colors[i + 1], f)!;
}

/// 轨迹点 - 记录位置和时间戳
class TrailPoint {
  final LatLng position;
  final DateTime timestamp;
  final double speed; // 记录该点的速度

  TrailPoint(this.position, this.timestamp, this.speed);
}

/// 粒子数据 - 用于喷射粒子效果
class TrailParticle {
  double x, y;           // 屏幕坐标
  double vx, vy;         // 速度向量
  double baseVx, baseVy; // 基础速度向量（直线阶段）
  double size;            // 当前大小
  double life;            // 剩余生命
  double maxLife;         // 最大生命
  Color color;            // 粒子颜色
  
  TrailParticle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.baseVx,
    required this.baseVy,
    required this.size,
    required this.life,
    required this.maxLife,
    required this.color,
  });
  
  double get progress => 1 - life / maxLife; // 0=新生, 1=死亡
}

/// 成员拖尾数据
class MemberTrail {
  final String userId;
  final String name;
  final Color color;
  LatLng currentPos;       // 实际最新位置（来自服务端推送）
  LatLng displayPos;       // 当前显示位置（插值后，用于 Marker 定位）
  LatLng? previousPos;
  double speed; // m/s
  double heading; // 弧度
  DateTime? lastUpdate;
  MovementType? overrideMovementType;
  String skinId; // 轨迹皮肤 ID

  // 导航式插值：线性匀速 + 速度外推（数据没来时继续走不停）
  LatLng _lerpFrom;           // 插值起点
  LatLng _lerpTo;             // 插值终点 = currentPos
  DateTime? _lerpStartTime;  // 插值开始时间
  double _lerpDuration;       // 预计插值时长（秒），基于历史上报间隔
  double _velocityLat = 0;    // 速度向量纬度分量（度/秒）
  double _velocityLng = 0;    // 速度向量经度分量（度/秒）
  double _avgUpdateInterval = 2.0; // 平均上报间隔（秒），自适应
  bool needsInterpolation = false;

  // 轨迹历史点（最多保留120个，约行驶模式的8分钟，拖尾更长）
  final List<TrailPoint> _trailPoints = [];
  static const int _maxTrailPoints = 120;

  // 喷射粒子列表（用于 particle 皮肤）
  final List<TrailParticle> _particles = [];
  static const int _maxParticles = 300;

  // 不在移动时的淡出计时（秒）
  double fadeTimer = 0;

  // 版本号：每次修改递增，用于 shouldRepaint 判断
  int _version = 0;
  int get version => _version;

  MemberTrail({
    required this.userId,
    required this.name,
    required this.color,
    required this.currentPos,
    this.speed = 0,
    this.heading = 0,
    this.lastUpdate,
    this.overrideMovementType,
    this.skinId = 'default',
  }) : displayPos = currentPos,
       _lerpFrom = currentPos,
       _lerpTo = currentPos,
       _lerpDuration = 0;

  /// 获取只读轨迹点列表
  List<TrailPoint> get trailPoints => List.unmodifiable(_trailPoints);

  /// 获取只读粒子列表
  List<TrailParticle> get particles => List.unmodifiable(_particles);

  /// 更新位置
  void updatePosition(LatLng newPos, {double? gpsSpeed}) {
    previousPos = currentPos;
    final now = DateTime.now();

    // 先算上报间隔（在更新 lastUpdate 之前）
    double actualInterval = 0;
    if (lastUpdate != null) {
      actualInterval = now.difference(lastUpdate!).inMilliseconds / 1000.0;
    }

    // 速度计算
    if (gpsSpeed != null) {
      speed = gpsSpeed;
    } else if (actualInterval > 0) {
      final distance = const Distance().distance(currentPos, newPos);
      final calcSpeed = distance / actualInterval;
      if (distance < 3.0 && calcSpeed > 2.0) {
        speed = 0;
      } else {
        speed = calcSpeed;
      }
    }
    lastUpdate = now;

    // 计算方向（只在距离足够大时更新）
    if (previousPos != null) {
      final dist = const Distance().distance(previousPos!, newPos);
      if (dist > 5.0) {
        final dy = newPos.latitude - previousPos!.latitude;
        final dx = newPos.longitude - previousPos!.longitude;
        if (dx != 0 || dy != 0) {
          heading = atan2(dy, dx);
        }
      }
    }

    currentPos = newPos;
    needsInterpolation = true;

    // 更新平均上报间隔（指数平滑）
    if (actualInterval > 0.1 && actualInterval < 30) {
      _avgUpdateInterval = _avgUpdateInterval * 0.7 + actualInterval * 0.3;
    }

    // 启动新的线性插值：从当前 displayPos 匀速走到 newPos
    _lerpFrom = displayPos;
    _lerpTo = newPos;
    _lerpStartTime = now;
    _lerpDuration = _avgUpdateInterval.clamp(0.5, 5.0);

    // 计算速度向量（度/秒），用于外推
    if (previousPos != null && _avgUpdateInterval > 0) {
      _velocityLat = (newPos.latitude - previousPos!.latitude) / _avgUpdateInterval;
      _velocityLng = (newPos.longitude - previousPos!.longitude) / _avgUpdateInterval;
    }

    // 在移动时记录轨迹点
    if (isMoving) {
      _trailPoints.add(TrailPoint(newPos, DateTime.now(), speed));
      // 限制长度
      if (_trailPoints.length > _maxTrailPoints) {
        _trailPoints.removeAt(0);
      }
      fadeTimer = 1.0; // 重置淡出
    }

    _version++;
  }

  /// 每帧更新淡出计时
  void updateFade(double dt) {
    if (!isMoving && _trailPoints.isNotEmpty) {
      fadeTimer -= dt * 0.4; // 约2.5秒完全淡出
      if (fadeTimer <= 0) {
        fadeTimer = 0;
        _trailPoints.clear(); // 淡出完毕清除轨迹
      }
      _version++;
    }
  }

  /// 每帧插值：导航风格——线性匀速移动 + 速度外推（数据没来时继续走）
  void interpolate(double dt) {
    if (!needsInterpolation || _lerpStartTime == null) return;

    final elapsed = DateTime.now().difference(_lerpStartTime!).inMilliseconds / 1000.0;

    if (_lerpDuration > 0 && elapsed < _lerpDuration) {
      // 阶段1：线性插值——匀速从 _lerpFrom 走到 _lerpTo
      final t = (elapsed / _lerpDuration).clamp(0.0, 1.0);
      displayPos = LatLng(
        _lerpFrom.latitude + (_lerpTo.latitude - _lerpFrom.latitude) * t,
        _lerpFrom.longitude + (_lerpTo.longitude - _lerpFrom.longitude) * t,
      );
    } else {
      // 阶段2：外推——到达 _lerpTo 后按速度向量继续前进，不等数据
      // 这样标记永远不会卡住，而是一直在走
      final extraTime = elapsed - _lerpDuration;

      // 只在真实移动时外推（速度 > 0.5m/s）
      if (speed > 0.5 && extraTime < 5.0) {
        displayPos = LatLng(
          _lerpTo.latitude + _velocityLat * extraTime,
          _lerpTo.longitude + _velocityLng * extraTime,
        );
      } else {
        // 静止或外推太久：停在目标位置
        displayPos = _lerpTo;
        needsInterpolation = false;
      }
    }
    _version++;
  }

  /// 清除过期的轨迹点（超过5分钟的，拖尾更长需要更长的保留时间）
  void cleanOldPoints() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    final oldLen = _trailPoints.length;
    while (_trailPoints.isNotEmpty && _trailPoints.first.timestamp.isBefore(cutoff)) {
      _trailPoints.removeAt(0);
    }
    if (_trailPoints.length != oldLen) _version++;
  }

  bool get isMoving {
    if (overrideMovementType == MovementType.still) return false;
    if (overrideMovementType != null && overrideMovementType != MovementType.still) return true;
    return speed > 1.0;
  }

  MovementType get movementType {
    if (overrideMovementType != null) return overrideMovementType!;
    if (speed < 1.0) return MovementType.still;
    if (speed < 3.5) return MovementType.walking;
    if (speed < 8.0) return MovementType.cycling;
    return MovementType.driving;
  }
}

enum MovementType { still, walking, cycling, driving }

// ==================== 拖尾渲染层 ====================

class TrailParticleLayer extends StatefulWidget {
  final MapController mapController;
  final Map<String, MemberTrail> memberTrails;

  const TrailParticleLayer({
    super.key,
    required this.mapController,
    required this.memberTrails,
  });

  @override
  State<TrailParticleLayer> createState() => _TrailParticleLayerState();
}

class _TrailParticleLayerState extends State<TrailParticleLayer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _wasAnimating = false;

  /// 检查是否有任何可见的拖尾
  bool get _hasVisibleTrails {
    for (final trail in widget.memberTrails.values) {
      if (trail.trailPoints.isNotEmpty || trail.isMoving) return true;
      if (trail.skinId == 'particle' && trail.particles.isNotEmpty) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(days: 365),
    );
    // 不自动 repeat，等有拖尾时再启动
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 根据是否有可见拖尾，动态启停动画
    final shouldAnimate = _hasVisibleTrails;
    if (shouldAnimate && !_controller.isAnimating) {
      _controller.repeat();
      _wasAnimating = true;
    } else if (!shouldAnimate && _controller.isAnimating) {
      _controller.stop();
      _wasAnimating = false;
    }

    if (!shouldAnimate) {
      // 无拖尾时返回空 SizedBox，完全不绘制
      return const SizedBox.shrink();
    }

    return TrailAnimatedBuilder(
      listenable: _controller,
      builder: (context, _) {
        return IgnorePointer(
          child: CustomPaint(
            painter: _TrailPainter(
              memberTrails: widget.memberTrails,
              mapController: widget.mapController,
            ),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

/// Jagat 风格拖尾绘制器
/// 沿轨迹路径绘制渐变拖尾带，头粗尾细，方向跟随
class _TrailPainter extends CustomPainter {
  final Map<String, MemberTrail> memberTrails;
  final MapController mapController;
  final int _snapshotVersion; // 捕获的版本快照

  _TrailPainter({
    required this.memberTrails,
    required this.mapController,
  }) : _snapshotVersion = _computeVersion(memberTrails);

  /// 计算所有 trail 的版本总和
  static int _computeVersion(Map<String, MemberTrail> trails) {
    int v = 0;
    for (final trail in trails.values) {
      v += trail.version;
    }
    return v;
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final trail in memberTrails.values) {
      _drawTrail(canvas, trail, size);
    }
  }

  void _drawTrail(Canvas canvas, MemberTrail trail, Size size) {
    final points = trail.trailPoints;
    if (points.isEmpty) return;

    // 更新淡出
    trail.updateFade(1 / 30);
    trail.cleanOldPoints();

    // 将轨迹点转为屏幕坐标
    final screenPoints = <Offset>[];
    for (final p in points) {
      final sp = _latLngToPixel(p.position, size);
      if (sp != null) screenPoints.add(sp);
    }
    final headPos = _latLngToPixel(trail.displayPos, size);
    if (headPos != null) screenPoints.add(headPos);

    if (screenPoints.length < 2) return;

    // 粒子皮肤：先画地面线条，再画喷射粒子
    if (trail.skinId == 'particle') {
      // 根据速度计算线条颜色（与粒子同步）
      final speedForColor = (trail.speed / 15.0).clamp(0.0, 1.0);
      final lineColor = lerpTrailColor(speedForColor, gradient: kParticleGradient);
      // 画地面线条（半透明，作为轨迹基底）
      _drawTrailLineWithColor(canvas, screenPoints, 5.0, trail.fadeTimer, lineColor, alphaMultiplier: 0.7);
      // 画喷射粒子
      _drawParticleTrail(canvas, trail, size);
      return;
    }

    // 根据移动类型确定拖尾参数
    final type = trail.movementType;
    final fadeAlpha = trail.fadeTimer; // 淡出系数 0~1
    final gradient = getTrailGradient(trail.skinId);

    // 拖尾带宽
    double baseWidth;
    switch (type) {
      case MovementType.driving:
        baseWidth = 14.0;
        break;
      case MovementType.cycling:
        baseWidth = 10.0;
        break;
      case MovementType.walking:
        baseWidth = 7.0;
        break;
      case MovementType.still:
        baseWidth = 5.0;
        break;
    }

    double headColorT;
    switch (type) {
      case MovementType.driving:
        headColorT = 0.45;
        break;
      case MovementType.cycling:
        headColorT = 0.25;
        break;
      case MovementType.walking:
        headColorT = 0.1;
        break;
      case MovementType.still:
        headColorT = 0.05;
        break;
    }

    // 绘制3层：光晕层 → 主体层 → 中心高亮线
    _drawTrailLine(canvas, screenPoints, baseWidth * 3.0, headColorT, fadeAlpha, gradient,
        glowBlur: 6.0, alphaMultiplier: 0.2);
    _drawTrailLine(canvas, screenPoints, baseWidth, headColorT, fadeAlpha, gradient,
        glowBlur: 2.0, alphaMultiplier: 0.7);
    _drawTrailLine(canvas, screenPoints, baseWidth * 0.4, headColorT, fadeAlpha, gradient,
        glowBlur: 0, alphaMultiplier: 1.0, whiten: 0.4);
  }

  /// 绘制一条沿路径的渐变拖尾线
  void _drawTrailLine(
    Canvas canvas,
    List<Offset> points,
    double maxWidth,
    double headColorT,
    double fadeAlpha,
    List<Color> gradient, {
    double glowBlur = 0,
    double alphaMultiplier = 1.0,
    double whiten = 0,
  }) {
    final totalPts = points.length;
    if (totalPts < 2) return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (glowBlur > 0) {
      paint.maskFilter = MaskFilter.blur(BlurStyle.normal, glowBlur);
    }

    // 逐段绘制，每段有独立的宽度和颜色
    for (int i = 0; i < totalPts - 1; i++) {
      final t0 = i / (totalPts - 1);
      final t1 = (i + 1) / (totalPts - 1);

      final w0 = maxWidth * (0.1 + 0.9 * _easeOut(t0));
      final w1 = maxWidth * (0.1 + 0.9 * _easeOut(t1));

      final colorT0 = (headColorT - 0.35 * (1 - t0)).clamp(0.0, 1.0);
      final colorT1 = (headColorT - 0.35 * (1 - t1)).clamp(0.0, 1.0);

      final alpha0 = (t0 * 0.85 + 0.15) * fadeAlpha * alphaMultiplier;
      final alpha1 = (t1 * 0.85 + 0.15) * fadeAlpha * alphaMultiplier;

      final midColorT = (colorT0 + colorT1) / 2;
      var color = lerpTrailColor(midColorT, gradient: gradient);

      if (whiten > 0) {
        color = Color.lerp(color, Colors.white, whiten)!;
      }

      paint.color = Color.fromRGBO(
        color.red,
        color.green,
        color.blue,
        ((alpha0 + alpha1) / 2).clamp(0.0, 1.0),
      );
      paint.strokeWidth = (w0 + w1) / 2;

      canvas.drawLine(points[i], points[i + 1], paint);
    }
  }

  double _easeOut(double t) => 1 - (1 - t) * (1 - t);

  /// 绘制单色拖尾线（用于粒子皮肤的地面线条）
  void _drawTrailLineWithColor(
    Canvas canvas,
    List<Offset> points,
    double maxWidth,
    double fadeAlpha,
    Color baseColor, {
    double alphaMultiplier = 1.0,
  }) {
    final totalPts = points.length;
    if (totalPts < 2) return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.0);

    for (int i = 0; i < totalPts - 1; i++) {
      final t0 = i / (totalPts - 1);
      final t1 = (i + 1) / (totalPts - 1);

      // 宽度：头部粗，尾部细
      final w0 = maxWidth * (0.1 + 0.9 * _easeOut(t0));
      final w1 = maxWidth * (0.1 + 0.9 * _easeOut(t1));

      // 透明度：头部亮，尾部淡
      final alpha0 = (t0 * 0.85 + 0.15) * fadeAlpha * alphaMultiplier;
      final alpha1 = (t1 * 0.85 + 0.15) * fadeAlpha * alphaMultiplier;

      paint.color = Color.fromRGBO(
        baseColor.red,
        baseColor.green,
        baseColor.blue,
        ((alpha0 + alpha1) / 2).clamp(0.0, 1.0),
      );
      paint.strokeWidth = (w0 + w1) / 2;

      canvas.drawLine(points[i], points[i + 1], paint);
    }
  }

  /// 粒子拖尾绘制 - 从头像位置喷射彩色粒子
  void _drawParticleTrail(Canvas canvas, MemberTrail trail, Size size) {
    final speed = trail.speed;
    final fadeAlpha = trail.fadeTimer;
    
    // 获取头像屏幕位置
    final headPos = _latLngToPixel(trail.displayPos, size);
    if (headPos == null) return;
    
    // 速度决定粒子生成速率
    final speedFactor = (speed / 15.0).clamp(0.1, 1.0);
    
    // 生成新粒子（从头像边缘向后喷射）
    if (trail.isMoving && fadeAlpha > 0) {
      final random = Random(DateTime.now().millisecondsSinceEpoch);
      
      // 地理heading转屏幕角度：屏幕Y轴向下，需要取反
      final screenHeading = -trail.heading;
      // 反方向角度（严格与行进方向相反）
      final reverseAngle = screenHeading + pi;
      
      // 所有速度档位：粒子数和速度恒定，只有颜色变化
      final spawnCount = 4;
      
      for (int i = 0; i < spawnCount; i++) {
        // 从头像后边缘生成
        final spawnDist = 16.0 + random.nextDouble() * 6;

        // 生成角度：反方向 ±12度范围内随机（扇形喷射）
        final angleOffset = (random.nextDouble() - 0.5) * 0.42;
        final particleAngle = reverseAngle + angleOffset;
        
        final px = headPos.dx + cos(particleAngle) * spawnDist;
        final py = headPos.dy + sin(particleAngle) * spawnDist;
        
        // 速度恒定
        final particleSpeed = 3.0 + random.nextDouble() * 1.0;
        final baseVx = cos(particleAngle) * particleSpeed;
        final baseVy = sin(particleAngle) * particleSpeed;
        
        // 大小：恒定 3~5px
        final particleSize = 3.0 + random.nextDouble() * 2.0;
        
        // 生命：50 ~ 80帧
        final life = 50.0 + random.nextDouble() * 30.0;
        
        // 颜色：根据速度在梯度中取色
        final colorT = speedFactor.clamp(0.0, 1.0);
        final baseColor = lerpTrailColor(colorT, gradient: kParticleGradient);
        final color = Color.fromRGBO(
          (baseColor.red + random.nextInt(40) - 20).clamp(0, 255),
          (baseColor.green + random.nextInt(40) - 20).clamp(0, 255),
          (baseColor.blue + random.nextInt(40) - 20).clamp(0, 255),
          1.0,
        );
        
        trail._particles.add(TrailParticle(
          x: px, y: py,
          vx: baseVx, vy: baseVy,
          baseVx: baseVx, baseVy: baseVy,
          size: particleSize,
          life: life, maxLife: life,
          color: color,
        ));
      }
      
      // 限制粒子总数
      while (trail._particles.length > MemberTrail._maxParticles) {
        trail._particles.removeAt(0);
      }
    }
    
    // 更新并绘制粒子
    for (int i = trail._particles.length - 1; i >= 0; i--) {
      final p = trail._particles[i];
      
      // 粒子沿生成方向飞行，逐渐减速
      final t = p.progress; // 0=新生, 1=死亡
      
      // 速度随生命衰减
      final speedMult = 1.0 - t * 0.5; // 逐渐减速
      p.x += p.baseVx * speedMult;
      p.y += p.baseVy * speedMult;
      
      p.life--;
      
      // 移除死亡粒子
      if (p.life <= 0) {
        trail._particles.removeAt(i);
        continue;
      }
      
      // 根据生命阶段计算透明度和大小（t 在上面已定义）
      final alpha = (1 - t * 1.2).clamp(0.0, 0.5) * fadeAlpha;
      final sz = p.size * (1 - t * 0.6); // 越老越小
      
      if (alpha <= 0 || sz <= 0) continue;
      
      // 绘制粒子光晕
      final glowPaint = Paint()
        ..color = Color.fromRGBO(p.color.red, p.color.green, p.color.blue, alpha * 0.25)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sz * 0.8);
      canvas.drawCircle(Offset(p.x, p.y), sz * 1.2, glowPaint);
      
      // 绘制粒子主体
      final mainPaint = Paint()
        ..color = Color.fromRGBO(p.color.red, p.color.green, p.color.blue, alpha);
      canvas.drawCircle(Offset(p.x, p.y), sz, mainPaint);
      
      // 绘制高亮内核（更小更亮）
      final corePaint = Paint()
        ..color = Color.fromRGBO(
          (p.color.red + 100).clamp(0, 255),
          (p.color.green + 100).clamp(0, 255),
          (p.color.blue + 100).clamp(0, 255),
          alpha * 0.4,
        );
      canvas.drawCircle(Offset(p.x, p.y), sz * 0.35, corePaint);
    }
  }

  Offset? _latLngToPixel(LatLng pos, Size size) {
    try {
      final point = mapController.camera.latLngToScreenPoint(pos);
      return Offset(point.x.toDouble(), point.y.toDouble());
    } catch (_) {
      return null;
    }
  }

  @override
  bool shouldRepaint(covariant _TrailPainter oldDelegate) {
    // 只在轨迹数据实际变化时重绘
    return _snapshotVersion != oldDelegate._snapshotVersion;
  }
}

/// TrailAnimatedBuilder - 简化版的 AnimatedBuilder
class TrailAnimatedBuilder extends AnimatedWidget {
  final Widget Function(BuildContext context, Widget? child) builder;
  final Widget? child;

  const TrailAnimatedBuilder({
    super.key,
    required super.listenable,
    required this.builder,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return builder(context, child);
  }
}
