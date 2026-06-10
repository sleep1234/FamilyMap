import 'package:flutter/material.dart';
import 'trail_particles.dart';

/// 成员地图标记 - 家守 FamilyGuard 风格
/// 设计规格：从上到下 = 速度标签(移动中) + 在线标签(在线) + 方形圆角头像 + 信息胶囊(停留时间|电池)
class MemberMarker extends StatefulWidget {
  final String name;
  final Color color;
  final bool isMe;
  final bool isOnline;
  final bool isMoving;
  final double heading; // 弧度
  final double speedMs; // 速度 m/s
  final MovementType movementType;
  final int? batteryLevel;
  final bool? isCharging;
  final int? stayMinutes; // 停留分钟数
  final VoidCallback? onTap;
  final int index;

  const MemberMarker({
    super.key,
    required this.name,
    required this.color,
    this.isMe = false,
    this.isOnline = true,
    this.isMoving = false,
    this.heading = 0,
    this.speedMs = 0,
    this.movementType = MovementType.still,
    this.batteryLevel,
    this.isCharging,
    this.stayMinutes,
    this.onTap,
    this.index = 0,
  });

  @override
  State<MemberMarker> createState() => _MemberMarkerState();
}

class _MemberMarkerState extends State<MemberMarker>
    with TickerProviderStateMixin {
  // 1. 入场动画
  late AnimationController _entranceCtrl;
  late Animation<double> _entranceScale;
  late Animation<double> _entranceY;

  // 2. 在线脉冲呼吸灯
  late AnimationController _pulseCtrl;

  // 3. 速度标签弹入
  late AnimationController _speedTagCtrl;

  // 4. 充电动画
  late AnimationController _chargeCtrl;

  @override
  void initState() {
    super.initState();

    // 入场弹跳
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _entranceScale = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _entranceCtrl, curve: const Cubic(0.34, 1.56, 0.64, 1)),
    );
    _entranceY = Tween<double>(begin: -60, end: 0).animate(
      CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOutCubic),
    );
    Future.delayed(Duration(milliseconds: 150 * widget.index), () {
      if (mounted) _entranceCtrl.forward();
    });

    // 脉冲呼吸灯 2s
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))
      ..repeat();

    // 速度标签弹入
    _speedTagCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    if (widget.isMoving) _speedTagCtrl.forward();

    // 充电动画
    _chargeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    if (widget.isCharging == true) _chargeCtrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant MemberMarker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isMoving && !oldWidget.isMoving) {
      _speedTagCtrl.forward(from: 0);
    } else if (!widget.isMoving && oldWidget.isMoving) {
      _speedTagCtrl.reverse();
    }
    if (widget.isCharging == true && oldWidget.isCharging != true) {
      _chargeCtrl.repeat(reverse: true);
    } else if (widget.isCharging != true && oldWidget.isCharging == true) {
      _chargeCtrl.stop();
    }
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    _pulseCtrl.dispose();
    _speedTagCtrl.dispose();
    _chargeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: TrailAnimatedBuilder(
        listenable: Listenable.merge([
          _entranceCtrl, _pulseCtrl, _speedTagCtrl, _chargeCtrl,
        ]),
        builder: (context, _) {
          final entranceOn = _entranceCtrl.value < 1.0;
          return Transform.translate(
            offset: entranceOn ? Offset(0, _entranceY.value) : Offset.zero,
            child: Transform.scale(
              scale: _entranceScale.value,
              child: Opacity(
                opacity: _entranceCtrl.value.clamp(0.0, 1.0),
                child: _buildMarkerContent(),
              ),
            ),
          );
        },
      ),
    );
  }

  // ==================== 标记主体：从上到下 ====================

  Widget _buildMarkerContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1. 速度标签（移动中才显示）
        if (widget.isMoving) _buildSpeedTag(),

        // 2. 在线标签（在线才显示）
        if (widget.isOnline) _buildOnlineTag(),

        // 3. 头像区域（在线脉冲 + 方形圆角头像）
        Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            if (widget.isOnline) _buildPulseRing(),
            _buildAvatarSquare(),
          ],
        ),

        // 4. 信息胶囊（停留时间 | 电池）
        _buildInfoCapsule(),
      ],
    );
  }

  // ---- 1. 速度标签 ----
  Widget _buildSpeedTag() {
    final speedKmh = (widget.speedMs * 3.6).toStringAsFixed(0);
    final tagColor = _speedTagColor();
    // 弹入动画
    final tagScale = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _speedTagCtrl, curve: const Cubic(0.34, 2.0, 0.64, 1)),
    );
    final tagY = Tween<double>(begin: -8, end: 0).animate(
      CurvedAnimation(parent: _speedTagCtrl, curve: Curves.easeOut),
    );
    return Transform.translate(
      offset: Offset(0, tagY.value),
      child: Transform.scale(
        scale: tagScale.value,
        child: Opacity(
          opacity: _speedTagCtrl.value,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: tagColor.withOpacity(0.9),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$speedKmh km/h',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }

  // ---- 2. 在线标签 ----
  Widget _buildOnlineTag() {
    return Container(
      margin: const EdgeInsets.only(bottom: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFA8D8FF).withOpacity(0.85),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Text(
        '在线',
        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFF2563EB)),
      ),
    );
  }

  // ---- 3. 方形圆角头像 ----
  Widget _buildAvatarSquare() {
    final size = 44.0;
    final radius = 12.0;

    // 离线
    if (!widget.isOnline) {
      return Container(
        width: size, height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: Colors.grey.shade600.withOpacity(0.6),
          border: Border.all(color: Colors.grey.shade500, width: 2),
        ),
        child: Center(
          child: Text(
            widget.name.isNotEmpty ? widget.name[0].toUpperCase() : '?',
            style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 18, fontWeight: FontWeight.w800),
          ),
        ),
      );
    }

    // 自己（蓝色粗边框 + 外发光）
    if (widget.isMe) {
      final chargeGlow = widget.isCharging == true
          ? BoxShadow(
              color: const Color(0xFF34C759).withOpacity(0.3 + 0.3 * _chargeCtrl.value),
              blurRadius: 12 + 8 * _chargeCtrl.value,
              spreadRadius: 2,
            )
          : const BoxShadow(color: Colors.transparent);

      return Container(
        width: size, height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: widget.color,
          border: Border.all(color: const Color(0xFF4A90D9), width: 3),
          boxShadow: [
            BoxShadow(color: const Color(0xFF4A90D9).withOpacity(0.5), blurRadius: 10, spreadRadius: 2),
            chargeGlow,
          ],
        ),
        child: Center(
          child: widget.isCharging == true
              ? _buildChargingIcon()
              : Text(
                  widget.name.isNotEmpty ? widget.name[0].toUpperCase() : '?',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
                ),
        ),
      );
    }

    // 在线好友（白色细边框）
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: widget.color,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(color: widget.color.withOpacity(0.4), blurRadius: 6, spreadRadius: 1),
        ],
      ),
      child: Center(
        child: widget.isCharging == true
            ? _buildChargingIcon()
            : Text(
                widget.name.isNotEmpty ? widget.name[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
              ),
      ),
    );
  }

  // ---- 4. 信息胶囊 ----
  Widget _buildInfoCapsule() {
    // 离线用户不显示信息胶囊
    if (!widget.isOnline) {
      return _buildNameOnly();
    }

    final stayText = _formatStayTime(widget.stayMinutes);
    final batteryLevel = widget.batteryLevel;
    final isCharging = widget.isCharging == true;
    final hasBoth = stayText != null && batteryLevel != null;

    // 都没有时只显示名字
    if (stayText == null && batteryLevel == null) {
      return _buildNameOnly();
    }

    return Container(
      margin: const EdgeInsets.only(top: 3),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 停留时间
          if (stayText != null)
            Text(stayText, style: const TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.w500)),
          // 分隔竖线（两者都有时才显示）
          if (hasBoth) ...[
            const SizedBox(width: 4),
            Container(width: 1, height: 10, color: Colors.white24),
            const SizedBox(width: 4),
          ],
          // 电池图标 + 百分比
          if (batteryLevel != null) _buildBatteryIndicator(batteryLevel, isCharging),
        ],
      ),
    );
  }

  /// 离线用户只显示名字
  Widget _buildNameOnly() {
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.grey.shade700,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        widget.isMe ? '我' : widget.name,
        style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 10, fontWeight: FontWeight.w400),
        maxLines: 1, overflow: TextOverflow.ellipsis,
      ),
    );
  }

  // ---- 电池指示器 ----
  Widget _buildBatteryIndicator(int level, bool charging) {
    // 电池颜色
    Color batteryColor;
    if (level > 50) {
      batteryColor = const Color(0xFF34C759);
    } else if (level > 20) {
      batteryColor = const Color(0xFFFFC107);
    } else {
      batteryColor = const Color(0xFFFF6B6B);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 电池外壳
        CustomPaint(
          size: const Size(16, 10),
          painter: _BatteryPainter(
            level: level / 100.0,
            color: batteryColor,
            showBolt: charging,
            boltOpacity: charging ? 0.5 + 0.5 * _chargeCtrl.value : 0,
          ),
        ),
        const SizedBox(width: 2),
        Text('$level%', style: TextStyle(color: batteryColor, fontSize: 9, fontWeight: FontWeight.w600)),
      ],
    );
  }

  // ---- 脉冲呼吸灯 ----
  Widget _buildPulseRing() {
    final ringColor = widget.isMe ? const Color(0xFF4A90D9) : widget.color;
    return CustomPaint(
      size: const Size(68, 68),
      painter: _PulseRingPainter(progress: _pulseCtrl.value, color: ringColor),
    );
  }

  // ---- 充电闪电图标 ----
  Widget _buildChargingIcon() {
    final boltOpacity = 0.5 + 0.5 * _chargeCtrl.value;
    return Icon(Icons.bolt, color: Colors.white.withOpacity(boltOpacity), size: 20);
  }

  // ---- 工具方法 ----

  String? _formatStayTime(int? minutes) {
    if (minutes == null || minutes <= 0) return null;
    if (minutes < 60) return '$minutes分钟';
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    if (hours < 24) return mins > 0 ? '${hours}h${mins}m' : '${hours}小时';
    final days = hours ~/ 24;
    final remainHours = hours % 24;
    return remainHours > 0 ? '${days}d${remainHours}h' : '${days}天';
  }

  Color _speedTagColor() {
    switch (widget.movementType) {
      case MovementType.walking: return const Color(0xFF4CAF50);
      case MovementType.cycling: return const Color(0xFFFF9800);
      case MovementType.driving: return const Color(0xFFF44336);
      case MovementType.still: return const Color(0xFF9E9E9E);
    }
  }
}

// ==================== 脉冲呼吸灯画笔 ====================
class _PulseRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  _PulseRingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = 22.0; // 方形圆角头像半径约22
    for (int i = 0; i < 2; i++) {
      final phase = (progress + i * 0.4) % 1.0;
      final scale = 1.0 + phase * 0.6;
      final opacity = (1.0 - phase) * 0.5;
      final paint = Paint()
        ..color = color.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(center, baseRadius * scale, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PulseRingPainter old) => old.progress != progress;
}

// ==================== 电池图标画笔 ====================
class _BatteryPainter extends CustomPainter {
  final double level; // 0.0 ~ 1.0
  final Color color;
  final bool showBolt;
  final double boltOpacity;
  _BatteryPainter({
    required this.level,
    required this.color,
    required this.showBolt,
    required this.boltOpacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2..color = Colors.white70;
    final fillPaint = Paint()..style = PaintingStyle.fill..color = color;

    // 外壳 (圆角矩形)
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 1, size.width - 3, size.height - 2),
      const Radius.circular(2),
    );
    canvas.drawRRect(bodyRect, paint);

    // 右侧小正极凸起
    canvas.drawRect(Rect.fromLTWH(size.width - 2.5, 3, 2, size.height - 6), paint);

    // 内部填充
    final fillWidth = (size.width - 5) * level.clamp(0.0, 1.0);
    if (fillWidth > 0) {
      final fillRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(1, 2, fillWidth, size.height - 4),
        const Radius.circular(1),
      );
      canvas.drawRRect(fillRect, fillPaint);
    }

    // 充电闪电
    if (showBolt) {
      final boltPaint = Paint()
        ..color = Colors.white.withOpacity(boltOpacity)
        ..style = PaintingStyle.fill;
      final cx = size.width / 2 - 1;
      final cy = size.height / 2;
      final path = Path()
        ..moveTo(cx - 1, cy - 3)
        ..lineTo(cx + 1.5, cy - 0.5)
        ..lineTo(cx, cy - 0.5)
        ..lineTo(cx + 1, cy + 3)
        ..lineTo(cx - 1.5, cy + 0.5)
        ..lineTo(cx, cy + 0.5)
        ..close();
      canvas.drawPath(path, boltPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _BatteryPainter old) =>
      old.level != level || old.boltOpacity != boltOpacity;
}
