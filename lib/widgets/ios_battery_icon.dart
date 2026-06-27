import 'package:flutter/material.dart';

/// iOS 风格横卧电池指示器
/// - 电池外壳（圆角矩形 + 右侧小正极头）
/// - 内部填充条（按电量比例）
/// - 充电时在内部叠加 Icons.bolt 闪电图标
class IOSBatteryIcon extends StatelessWidget {
  final int level;       // 0-100
  final bool charging;
  final double size;     // 整体高度，宽度按比例自动计算

  const IOSBatteryIcon({
    super.key,
    required this.level,
    this.charging = false,
    this.size = 14,
  });

  @override
  Widget build(BuildContext context) {
    // 计算颜色
    final Color fillColor;
    if (charging) {
      fillColor = const Color(0xFF34C759);
    } else if (level > 50) {
      fillColor = const Color(0xFF34C759);
    } else if (level > 20) {
      fillColor = const Color(0xFFFFC107);
    } else {
      fillColor = const Color(0xFFFF6B6B);
    }

    final bodyColor = charging ? const Color(0xFF34C759) : const Color(0xFF94A3B8);
    final capWidth = size * 0.18;

    return SizedBox(
      width: size * 1.75,
      height: size,
      child: Stack(
        children: [
          // 电池外壳 + 填充条（CustomPaint，不含闪电）
          CustomPaint(
            size: Size(size * 1.75, size),
            painter: _IOSBatteryPainter(
              level: level,
              fillColor: fillColor,
              bodyColor: bodyColor,
            ),
          ),
          // 充电闪电图标：居中在电池主体区域（排除右侧正极头）
          if (charging)
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(right: capWidth),
                child: Center(
                  child: Icon(Icons.bolt, color: Colors.white, size: size * 0.85),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _IOSBatteryPainter extends CustomPainter {
  final int level;
  final Color fillColor;
  final Color bodyColor;

  _IOSBatteryPainter({
    required this.level,
    required this.fillColor,
    required this.bodyColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = size.height / 7;  // 外壳线宽
    final capWidth = size.height * 0.18;  // 正极头宽度
    final capHeight = size.height * 0.42; // 正极头高度
    final radius = size.height / 4.5;     // 外壳圆角

    final bodyWidth = size.width - capWidth - strokeWidth / 2;
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(strokeWidth / 2, strokeWidth / 2, bodyWidth, size.height - strokeWidth),
      Radius.circular(radius),
    );

    // 1. 画外壳
    final bodyPaint = Paint()
      ..color = bodyColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawRRect(bodyRect, bodyPaint);

    // 2. 画正极头（右侧小凸起）
    final capRect = Rect.fromCenter(
      center: Offset(size.width - capWidth / 2, size.height / 2),
      width: capWidth,
      height: capHeight,
    );
    final capPaint = Paint()
      ..color = bodyColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(capRect, Radius.circular(capWidth / 3)),
      capPaint,
    );

    // 3. 画内部填充条
    final innerPadding = strokeWidth * 0.8;
    final innerLeft = strokeWidth / 2 + innerPadding;
    final innerTop = strokeWidth / 2 + innerPadding;
    final innerWidth = bodyWidth - innerPadding * 2;
    final innerHeight = size.height - strokeWidth - innerPadding * 2;
    final fillWidth = innerWidth * (level.clamp(0, 100) / 100);

    if (fillWidth > 0) {
      final fillRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(innerLeft, innerTop, fillWidth, innerHeight),
        Radius.circular(radius * 0.5),
      );
      final fillPaint = Paint()
        ..color = fillColor
        ..style = PaintingStyle.fill;
      canvas.drawRRect(fillRect, fillPaint);
    }

    // 闪电由 Icons.bolt 图标叠加，不再手绘
  }

  @override
  bool shouldRepaint(covariant _IOSBatteryPainter oldDelegate) {
    return oldDelegate.level != level || oldDelegate.fillColor != fillColor || oldDelegate.bodyColor != bodyColor;
  }
}
