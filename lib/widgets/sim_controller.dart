import 'dart:math';
import 'package:flutter/material.dart';

// ==================== 模拟控制器 ====================
// 浮窗摇杆 + 速度预设，用于在室内测试拖尾/测速/碰撞检测等功能
// 摇杆控制方向，滑条/预设按钮控制速度，生成的位置直接流入 _handlePositionUpdate

/// 模拟控制器回调
typedef SimPositionCallback = void Function({
  required double bearing,     // 方位角（度），0=北 90=东
  required double speedMs,     // 速度 m/s
  required bool isMoving,      // 摇杆是否按下
});

class SimControlPanel extends StatefulWidget {
  final SimPositionCallback onSimUpdate;
  final VoidCallback onStop;   // 关闭模拟

  const SimControlPanel({
    super.key,
    required this.onSimUpdate,
    required this.onStop,
  });

  @override
  State<SimControlPanel> createState() => _SimControlPanelState();
}

class _SimControlPanelState extends State<SimControlPanel> {
  // 摇杆状态
  double _joystickDx = 0; // -1(西) ~ 1(东)
  double _joystickDy = 0; // -1(北) ~ 1(南)
  bool _joystickActive = false;

  // 速度配置（m/s）
  double _simSpeed = 1.5; // 默认步行
  static const List<_SpeedPreset> _presets = [
    _SpeedPreset('静止', 0),
    _SpeedPreset('步行', 1.5),
    _SpeedPreset('骑行', 5.0),
    _SpeedPreset('驾车', 15.0),
    _SpeedPreset('高速', 33.0),
  ];

  // 摇杆参数
  static const double _baseRadius = 50; // 底盘半径
  static const double _knobRadius = 22; // 摇杆球半径

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFF8C42), width: 2),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 12)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题行
          Row(
            children: [
              Container(
                width: 8, height: 8,
                decoration: const BoxDecoration(color: Color(0xFFFF8C42), shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              const Text('模拟驾驶', style: TextStyle(color: Color(0xFFFF8C42), fontSize: 13, fontWeight: FontWeight.w700)),
              const Spacer(),
              GestureDetector(
                onTap: widget.onStop,
                child: const Icon(Icons.close, color: Color(0xFF94A3B8), size: 18),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // 摇杆 + 速度信息
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 摇杆
              _buildJoystick(),
              const SizedBox(width: 16),
              // 右侧：速度 + 方向信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${(_simSpeed * 3.6).toStringAsFixed(0)} km/h',
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _joystickActive ? _bearingToDirection(_joystickDx, _joystickDy) : '松开暂停',
                      style: TextStyle(
                        color: _joystickActive ? const Color(0xFF10B981) : const Color(0xFF94A3B8),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 速度滑条
                    Text('速度调节', style: TextStyle(color: Colors.grey.shade400, fontSize: 10)),
                    SliderTheme(
                      data: SliderThemeData(
                        activeTrackColor: const Color(0xFFFF8C42),
                        inactiveTrackColor: const Color(0xFF334155),
                        thumbColor: const Color(0xFFFF8C42),
                        overlayColor: const Color(0xFFFF8C42).withOpacity(0.2),
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                      ),
                      child: Slider(
                        value: _simSpeed,
                        min: 0,
                        max: 40,
                        onChanged: (v) {
                          setState(() => _simSpeed = v);
                          _notifyUpdate();
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // 预设按钮
          const SizedBox(height: 6),
          Row(
            children: _presets.map((p) {
              final active = (_simSpeed - p.speed).abs() < 0.5;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _simSpeed = p.speed);
                      _notifyUpdate();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: active ? const Color(0xFFFF8C42) : const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: active ? const Color(0xFFFF8C42) : const Color(0xFF334155),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(p.label, style: TextStyle(
                            color: active ? Colors.white : const Color(0xFF94A3B8),
                            fontSize: 11, fontWeight: FontWeight.w600,
                          )),
                          Text('${(p.speed * 3.6).toStringAsFixed(0)}km/h', style: TextStyle(
                            color: active ? Colors.white70 : const Color(0xFF64748B),
                            fontSize: 9,
                          )),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  /// 构建摇杆控件
  Widget _buildJoystick() {
    return GestureDetector(
      onPanStart: (details) {
        _updateJoystick(details.localPosition);
        setState(() => _joystickActive = true);
      },
      onPanUpdate: (details) {
        _updateJoystick(details.localPosition);
      },
      onPanEnd: (_) {
        setState(() {
          _joystickDx = 0;
          _joystickDy = 0;
          _joystickActive = false;
        });
        // 松开 = 停止移动
        widget.onSimUpdate(bearing: 0, speedMs: _simSpeed, isMoving: false);
      },
      child: Container(
        width: _baseRadius * 2,
        height: _baseRadius * 2,
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF334155), width: 2),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 十字参考线
            Container(width: 1, height: _baseRadius * 1.6, color: const Color(0xFF334155)),
            Container(height: 1, width: _baseRadius * 1.6, color: const Color(0xFF334155)),
            // 摇杆球
            Transform.translate(
              offset: Offset(_joystickDx * (_baseRadius - _knobRadius), _joystickDy * (_baseRadius - _knobRadius)),
              child: Container(
                width: _knobRadius * 2,
                height: _knobRadius * 2,
                decoration: BoxDecoration(
                  color: _joystickActive ? const Color(0xFFFF8C42) : const Color(0xFF475569),
                  shape: BoxShape.circle,
                  boxShadow: _joystickActive
                      ? [const BoxShadow(color: Color(0xFFFF8C42), blurRadius: 8)]
                      : null,
                ),
                child: const Icon(Icons.navigation, color: Colors.white, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 更新摇杆位置
  void _updateJoystick(Offset localPosition) {
    final center = _baseRadius;
    double dx = (localPosition.dx - center) / (_baseRadius - _knobRadius);
    double dy = (localPosition.dy - center) / (_baseRadius - _knobRadius);
    // 限制在单位圆内
    final dist = sqrt(dx * dx + dy * dy);
    if (dist > 1) {
      dx /= dist;
      dy /= dist;
    }
    setState(() {
      _joystickDx = dx;
      _joystickDy = dy;
      _joystickActive = true;
    });
    _notifyUpdate();
  }

  /// 通知父组件更新
  void _notifyUpdate() {
    if (_joystickActive && (_joystickDx != 0 || _joystickDy != 0)) {
      // 计算方位角：0=北 90=东 180=南 270=西
      // dy<0(屏幕上)=北, dx>0=东
      final bearing = atan2(_joystickDx, -_joystickDy) * 180 / pi;
      widget.onSimUpdate(bearing: bearing, speedMs: _simSpeed, isMoving: true);
    } else {
      widget.onSimUpdate(bearing: 0, speedMs: _simSpeed, isMoving: false);
    }
  }

  /// 方位角转方向文字
  String _bearingToDirection(double dx, double dy) {
    if (dx == 0 && dy == 0) return '';
    final bearing = atan2(dx, -dy) * 180 / pi;
    if (bearing >= -22.5 && bearing < 22.5) return '向北';
    if (bearing >= 22.5 && bearing < 67.5) return '东北';
    if (bearing >= 67.5 && bearing < 112.5) return '向东';
    if (bearing >= 112.5 && bearing < 157.5) return '东南';
    if (bearing >= 157.5 || bearing < -157.5) return '向南';
    if (bearing >= -157.5 && bearing < -112.5) return '西南';
    if (bearing >= -112.5 && bearing < -67.5) return '向西';
    if (bearing >= -67.5 && bearing < -22.5) return '西北';
    return '';
  }
}

class _SpeedPreset {
  final String label;
  final double speed; // m/s
  const _SpeedPreset(this.label, this.speed);
}
