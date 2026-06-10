import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'trail_particles.dart';

/// 成员地图标记 - 家守 FamilyGuard 风格
/// 动画增强：入场弹跳 + 在线脉冲呼吸灯 + 速度标签弹入 + 充电动画
class MemberMarker extends StatefulWidget {
  final String name;
  final Color color;
  final bool isMe;
  final bool isOnline;
  final bool isMoving;
  final double heading; // 弧度
  final MovementType movementType;
  final int? batteryLevel;
  final bool? isCharging;
  final VoidCallback? onTap;
  final int index; // 交错入场用时序号

  const MemberMarker({
    super.key,
    required this.name,
    required this.color,
    this.isMe = false,
    this.isOnline = true,
    this.isMoving = false,
    this.heading = 0,
    this.movementType = MovementType.still,
    this.batteryLevel,
    this.isCharging,
    this.onTap,
    this.index = 0,
  });

  @override
  State<MemberMarker> createState() => _MemberMarkerState();
}

class _MemberMarkerState extends State<MemberMarker>
    with TickerProviderStateMixin {
  // 1. 入场动画控制器
  late AnimationController _entranceCtrl;
  late Animation<double> _entranceScale;
  late Animation<double> _entranceY;

  // 2. 脉冲呼吸灯控制器
  late AnimationController _pulseCtrl;

  // 3. 速度标签弹入控制器
  late AnimationController _speedTagCtrl;

  // 4. 充电动画控制器
  late AnimationController _chargeCtrl;

  bool _wasMoving = false;

  @override
  void initState() {
    super.initState();

    // 1. 入场动画：从上方弹入 + back缓动
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _entranceScale = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: const Cubic(0.34, 1.56, 0.64, 1), // back.out(1.7) 近似
      ),
    );
    _entranceY = Tween<double>(begin: -60, end: 0).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: Curves.easeOutCubic,
      ),
    );

    // 延时交错入场
    Future.delayed(Duration(milliseconds: 150 * widget.index), () {
      if (mounted) _entranceCtrl.forward();
    });

    // 2. 脉冲呼吸灯：2秒一次循环呼吸
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    // 3. 速度标签弹入
    _speedTagCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    if (widget.isMoving) {
      _speedTagCtrl.forward();
      _wasMoving = true;
    }

    // 4. 充电动画
    _chargeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    if (widget.isCharging == true) {
      _chargeCtrl.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant MemberMarker oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 速度状态变化时弹入速度标签
    if (widget.isMoving && !oldWidget.isMoving) {
      _speedTagCtrl.forward(from: 0);
      _wasMoving = true;
    } else if (!widget.isMoving && oldWidget.isMoving) {
      _speedTagCtrl.reverse();
      _wasMoving = false;
    }

    // 充电状态变化
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
          _entranceCtrl,
          _pulseCtrl,
          _speedTagCtrl,
          _chargeCtrl,
        ]),
        builder: (context, _) {
          // 入场位移 + 缩放
          final entranceOn = _entranceCtrl.value < 1.0;
          return Transform.translate(
            offset: entranceOn
                ? Offset(0, _entranceY.value)
                : Offset.zero,
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

  Widget _buildMarkerContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 速度标签弹入
        if (widget.isMoving)
          _buildSpeedTag(),

        // 在线标签
        if (widget.isOnline)
          _buildOnlineTag(),

        // 头像 + 脉冲
        Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            // 脉冲呼吸灯（仅在线时显示）
            if (widget.isOnline)
              _buildPulseRing(),
            // 头像
            if (widget.isMoving && widget.movementType == MovementType.driving)
              Transform.rotate(
                angle: widget.heading - 1.5708,
                child: _buildDrivingIcon(),
              )
            else
              _buildAvatarWithPin(),
          ],
        ),

        // 名字标签
        _buildNameLabel(),
      ],
    );
  }

  /// 速度标签 - 弹性弹入动画
  Widget _buildSpeedTag() {
    final speedKmh = (widget.movementType == MovementType.driving
            ? 40
            : widget.movementType == MovementType.cycling
                ? 18
                : widget.movementType == MovementType.walking
                    ? 5
                    : 0);

    final tagColor = _speedTagColor();

    // 弹入动画：从上方 8px 处 + 0.5 缩放弹入到 1.0
    final tagScale = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _speedTagCtrl,
        curve: const Cubic(0.34, 2.0, 0.64, 1), // back.out(2) 近似
      ),
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
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 在线小标签
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
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: Color(0xFF2563EB),
        ),
      ),
    );
  }

  /// 脉冲呼吸灯 - 多层环形波纹从头像向外扩散
  Widget _buildPulseRing() {
    final ringColor = widget.isMe
        ? const Color(0xFF4A90D9)
        : widget.color;

    return CustomPaint(
      size: const Size(70, 70),
      painter: _PulseRingPainter(
        progress: _pulseCtrl.value,
        color: ringColor,
      ),
    );
  }

  /// 头像 + 底部尖角
  Widget _buildAvatarWithPin() {
    if (widget.isMe) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildAvatarCircle(),
          CustomPaint(
            size: const Size(14, 8),
            painter: _PinPainter(color: const Color(0xFF4A90D9)),
          ),
        ],
      );
    } else {
      return _buildAvatarCircle();
    }
  }

  /// 头像圆形
  Widget _buildAvatarCircle() {
    // 离线
    if (!widget.isOnline) {
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.grey.shade600.withOpacity(0.6),
          border: Border.all(color: Colors.grey.shade500, width: 2),
        ),
        child: Center(
          child: Text(
            widget.name.isNotEmpty ? widget.name[0].toUpperCase() : '?',
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      );
    }

    // 自己 - 蓝色粗描边 + 外发光
    if (widget.isMe) {
      // 充电光晕
      final chargeGlow = widget.isCharging == true
          ? BoxShadow(
              color: const Color(0xFF34C759).withOpacity(0.3 + 0.3 * _chargeCtrl.value),
              blurRadius: 12 + 8 * _chargeCtrl.value,
              spreadRadius: 2,
            )
          : const BoxShadow(color: Colors.transparent);

      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color,
          border: Border.all(
            color: const Color(0xFF4A90D9),
            width: 3,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF4A90D9).withOpacity(0.5),
              blurRadius: 10,
              spreadRadius: 2,
            ),
            chargeGlow,
          ],
        ),
        child: Center(
          child: widget.isCharging == true
              ? _buildChargingIcon()
              : Text(
                  widget.name.isNotEmpty ? widget.name[0].toUpperCase() : '?',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
      );
    }

    // 在线好友 - 白色细边框
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.color,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
            color: widget.color.withOpacity(0.4),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Center(
        child: widget.isCharging == true
            ? _buildChargingIcon()
            : Text(
                widget.name.isNotEmpty ? widget.name[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
      ),
    );
  }

  /// 充电动画图标 - 闪电呼吸效果
  Widget _buildChargingIcon() {
    final boltOpacity = 0.5 + 0.5 * _chargeCtrl.value; // 0.5~1.0 呼吸
    return Icon(
      Icons.bolt,
      color: Colors.white.withOpacity(boltOpacity),
      size: 22,
    );
  }

  /// 名字标签
  Widget _buildNameLabel() {
    // 离线用户
    if (!widget.isOnline) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 80),
        child: Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.grey.shade700,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            widget.isMe ? '我' : widget.name,
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 10,
              fontWeight: FontWeight.w400,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // 在线用户
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 80),
      child: Container(
        margin: const EdgeInsets.only(top: 2),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          widget.isMe ? '我' : widget.name,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  /// 驾车图标
  Widget _buildDrivingIcon() {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.color,
        border: widget.isMe
            ? Border.all(color: const Color(0xFF4A90D9), width: 3)
            : Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
            color: widget.color.withOpacity(0.6),
            blurRadius: 12,
            spreadRadius: 3,
          ),
        ],
      ),
      child: const Center(
        child: Icon(
          Icons.directions_car,
          color: Colors.white,
          size: 22,
        ),
      ),
    );
  }

  /// 速度标签颜色
  Color _speedTagColor() {
    switch (widget.movementType) {
      case MovementType.walking:
        return const Color(0xFF4CAF50); // 绿色
      case MovementType.cycling:
        return const Color(0xFFFF9800); // 橙色
      case MovementType.driving:
        return const Color(0xFFF44336); // 红色
      case MovementType.still:
        return const Color(0xFF9E9E9E); // 灰色
    }
  }
}

/// 脉冲呼吸灯画笔 - 多层环形波纹从头像中心向外扩散
class _PulseRingPainter extends CustomPainter {
  final double progress; // 0.0 ~ 1.0，一圈动画周期
  final Color color;

  _PulseRingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = 24.0; // 头像半径

    // 绘制2层脉冲环，间隔0.4
    for (int i = 0; i < 2; i++) {
      final phase = (progress + i * 0.4) % 1.0;
      final scale = 1.0 + phase * 0.6; // 1.0 → 1.6 扩散
      final opacity = (1.0 - phase) * 0.5; // 0.5 → 0 消隐

      final paint = Paint()
        ..color = color.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;

      canvas.drawCircle(center, baseRadius * scale, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PulseRingPainter old) =>
      old.progress != progress;
}

/// 底部尖角画笔 - 蓝色小三角
class _PinPainter extends CustomPainter {
  final Color color;
  _PinPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
