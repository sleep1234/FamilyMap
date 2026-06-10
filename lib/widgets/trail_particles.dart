import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

// ==================== Jagat 风格轨迹拖尾 ====================
// 核心思路：记录移动轨迹点，绘制沿路径的渐变拖尾带
// - 速度快时拖尾长，尺寸恒定，跟随方向变化
// - 静止时拖尾渐消
// - 用8色梯度：头部亮色→尾部暗色

// 拖尾颜色梯度：翠绿 → 黄 → 橘 → 玫红（对标 Demo 的 TRAIL_COLORS）
const List<Color> kTrailGradient = [
  Color(0xFF00BF6A), // 翠绿
  Color(0xFF64D232), // 青绿
  Color(0xFFB4E61E), // 黄绿
  Color(0xFFFFDC00), // 亮黄
  Color(0xFFFFA000), // 橘橙
  Color(0xFFFF5028), // 红橙
  Color(0xFFC81E50), // 玫红
  Color(0xFF8C1478), // 深玫紫
];

/// 根据 t(0~1) 在梯度中插值获取颜色
Color lerpTrailColor(double t) {
  final idx = t * (kTrailGradient.length - 1);
  final i = idx.floor().clamp(0, kTrailGradient.length - 2);
  final f = idx - i;
  return Color.lerp(kTrailGradient[i], kTrailGradient[i + 1], f)!;
}

/// 轨迹点 - 记录位置和时间戳
class TrailPoint {
  final LatLng position;
  final DateTime timestamp;
  final double speed; // 记录该点的速度

  TrailPoint(this.position, this.timestamp, this.speed);
}

/// 成员拖尾数据
class MemberTrail {
  final String userId;
  final String name;
  final Color color;
  LatLng currentPos;
  LatLng? previousPos;
  double speed; // m/s
  double heading; // 弧度
  DateTime? lastUpdate;
  MovementType? overrideMovementType;

  // 轨迹历史点（最多保留120个，约行驶模式的8分钟，拖尾更长）
  final List<TrailPoint> _trailPoints = [];
  static const int _maxTrailPoints = 120;

  // 不在移动时的淡出计时（秒）
  double fadeTimer = 0;

  MemberTrail({
    required this.userId,
    required this.name,
    required this.color,
    required this.currentPos,
    this.speed = 0,
    this.heading = 0,
    this.lastUpdate,
    this.overrideMovementType,
  });

  /// 获取只读轨迹点列表
  List<TrailPoint> get trailPoints => List.unmodifiable(_trailPoints);

  /// 更新位置
  void updatePosition(LatLng newPos, {double? gpsSpeed}) {
    previousPos = currentPos;

    if (gpsSpeed != null) {
      speed = gpsSpeed;
    } else if (lastUpdate != null) {
      final now = DateTime.now();
      final dt = now.difference(lastUpdate!).inMilliseconds / 1000;
      if (dt > 0) {
        final distance = const Distance().distance(currentPos, newPos);
        final calcSpeed = distance / dt;
        if (distance < 3.0 && calcSpeed > 2.0) {
          speed = 0;
        } else {
          speed = calcSpeed;
        }
      }
      lastUpdate = now;
    } else {
      lastUpdate = DateTime.now();
    }

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

    // 在移动时记录轨迹点
    if (isMoving) {
      _trailPoints.add(TrailPoint(newPos, DateTime.now(), speed));
      // 限制长度
      if (_trailPoints.length > _maxTrailPoints) {
        _trailPoints.removeAt(0);
      }
      fadeTimer = 1.0; // 重置淡出
    }
  }

  /// 每帧更新淡出计时
  void updateFade(double dt) {
    if (!isMoving && _trailPoints.isNotEmpty) {
      fadeTimer -= dt * 0.4; // 约2.5秒完全淡出
      if (fadeTimer <= 0) {
        fadeTimer = 0;
        _trailPoints.clear(); // 淡出完毕清除轨迹
      }
    }
  }

  /// 清除过期的轨迹点（超过5分钟的，拖尾更长需要更长的保留时间）
  void cleanOldPoints() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    while (_trailPoints.isNotEmpty && _trailPoints.first.timestamp.isBefore(cutoff)) {
      _trailPoints.removeAt(0);
    }
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

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(days: 365),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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

  _TrailPainter({
    required this.memberTrails,
    required this.mapController,
  });

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
    trail.updateFade(1 / 60);
    trail.cleanOldPoints();

    // 将轨迹点转为屏幕坐标
    final screenPoints = <Offset>[];
    for (final p in points) {
      final sp = _latLngToPixel(p.position, size);
      if (sp != null) screenPoints.add(sp);
    }
    // 加上当前位置
    final headPos = _latLngToPixel(trail.currentPos, size);
    if (headPos != null) screenPoints.add(headPos);

    if (screenPoints.length < 2) return;

    // 根据移动类型确定拖尾参数
    final type = trail.movementType;
    final fadeAlpha = trail.fadeTimer; // 淡出系数 0~1

    // 拖尾带宽：速度快时恒定宽度（Jagat风格），不同运动类型宽度不同
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

    // 头部最亮颜色由移动类型决定
    // 驾车=黄色区域，骑行=绿色区域，步行=翠绿
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

    final totalPts = screenPoints.length;

    // 绘制3层：光晕层 → 主体层 → 中心高亮线
    // 从尾到头绘制，每段用渐变色

    // ---- 第1层：宽光晕（模糊，低透明度） ----
    _drawTrailLine(canvas, screenPoints, baseWidth * 3.0, headColorT, fadeAlpha,
        glowBlur: 6.0, alphaMultiplier: 0.2);

    // ---- 第2层：主体带 ----
    _drawTrailLine(canvas, screenPoints, baseWidth, headColorT, fadeAlpha,
        glowBlur: 2.0, alphaMultiplier: 0.7);

    // ---- 第3层：中心亮线 ----
    _drawTrailLine(canvas, screenPoints, baseWidth * 0.4, headColorT, fadeAlpha,
        glowBlur: 0, alphaMultiplier: 1.0, whiten: 0.4);
  }

  /// 绘制一条沿路径的渐变拖尾线
  /// 从尾（暗细透明）到头（亮粗不透明）
  void _drawTrailLine(
    Canvas canvas,
    List<Offset> points,
    double maxWidth,
    double headColorT,
    double fadeAlpha, {
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
      // t: 0=尾部, 1=头部
      final t0 = i / (totalPts - 1);
      final t1 = (i + 1) / (totalPts - 1);

      // 宽度：尾部细(0.1倍)，头部粗(1倍)，用easeOut曲线
      final w0 = maxWidth * (0.1 + 0.9 * _easeOut(t0));
      final w1 = maxWidth * (0.1 + 0.9 * _easeOut(t1));

      // 颜色：尾部暗色(t=headColorT-0.3)，头部亮色(t=headColorT)
      final colorT0 = (headColorT - 0.35 * (1 - t0)).clamp(0.0, 1.0);
      final colorT1 = (headColorT - 0.35 * (1 - t1)).clamp(0.0, 1.0);

      // 透明度：尾部淡，头部浓
      final alpha0 = (t0 * 0.85 + 0.15) * fadeAlpha * alphaMultiplier;
      final alpha1 = (t1 * 0.85 + 0.15) * fadeAlpha * alphaMultiplier;

      // 取中间值作为本段颜色（简化，避免每段创建Shader）
      final midT = (t0 + t1) / 2;
      final midColorT = (colorT0 + colorT1) / 2;
      var color = lerpTrailColor(midColorT);

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

  /// easeOut 缓动：快速达到目标值
  double _easeOut(double t) {
    return 1 - (1 - t) * (1 - t);
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
  bool shouldRepaint(covariant _TrailPainter oldDelegate) => true;
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
