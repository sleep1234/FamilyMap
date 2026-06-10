import 'dart:math';
import 'package:flutter/material.dart';

// ==================== 模拟控制器 ====================
// 浮窗摇杆 + 速度预设，用于在室内测试拖尾/测速/碰撞检测等功能
// 关键：固定宽度 280，用 Material 包裹保证触摸正确响应

typedef SimPositionCallback = void Function({
  required double bearing,
  required double speedMs,
  required bool isMoving,
});

class SimControlPanel extends StatefulWidget {
  final SimPositionCallback onSimUpdate;
  final VoidCallback onStop;

  const SimControlPanel({
    super.key,
    required this.onSimUpdate,
    required this.onStop,
  });

  @override
  State<SimControlPanel> createState() => _SimControlPanelState();
}

class _SimControlPanelState extends State<SimControlPanel> {
  double _joystickDx = 0;
  double _joystickDy = 0;
  bool _joystickActive = false;
  double _simSpeed = 1.5;

  static const List<_SpeedPreset> _presets = [
    _SpeedPreset('静止', 0),
    _SpeedPreset('步行', 1.5),
    _SpeedPreset('骑行', 5.0),
    _SpeedPreset('驾车', 15.0),
    _SpeedPreset('高速', 33.0),
  ];

  static const double _baseRadius = 44;
  static const double _knobRadius = 18;
  static const double _panelWidth = 280;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: _panelWidth,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.92),
          borderRadius: BorderRadius.circular(14),
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
                // 关闭按钮
                SizedBox(
                  width: 28, height: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.close, color: Color(0xFF94A3B8), size: 16),
                    onPressed: widget.onStop,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // 摇杆 + 速度
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildJoystick(),
                const SizedBox(width: 10),
                // 速度信息（固定宽度，不用 Expanded）
                SizedBox(
                  width: _panelWidth - _baseRadius * 2 - 10 - 10 - 20, // panelWidth - joystick - gaps - padding
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${(_simSpeed * 3.6).toStringAsFixed(0)} km/h',
                        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        _joystickActive ? _bearingToDirection(_joystickDx, _joystickDy) : '松开暂停',
                        style: TextStyle(
                          color: _joystickActive ? const Color(0xFF10B981) : const Color(0xFF94A3B8),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('速度', style: TextStyle(color: Colors.grey.shade400, fontSize: 9)),
                      SliderTheme(
                        data: SliderThemeData(
                          activeTrackColor: const Color(0xFFFF8C42),
                          inactiveTrackColor: const Color(0xFF334155),
                          thumbColor: const Color(0xFFFF8C42),
                          overlayColor: const Color(0xFFFF8C42).withOpacity(0.2),
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
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
            const SizedBox(height: 4),
            Row(
              children: _presets.map((p) {
                final active = (_simSpeed - p.speed).abs() < 0.5;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Material(
                      color: active ? const Color(0xFFFF8C42) : const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () {
                          setState(() => _simSpeed = p.speed);
                          _notifyUpdate();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          decoration: BoxDecoration(
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
                                fontSize: 10, fontWeight: FontWeight.w600,
                              )),
                              Text('${(p.speed * 3.6).toStringAsFixed(0)}', style: TextStyle(
                                color: active ? Colors.white70 : const Color(0xFF64748B),
                                fontSize: 8,
                              )),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildJoystick() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
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
            Container(width: 1, height: _baseRadius * 1.4, color: const Color(0xFF334155)),
            Container(height: 1, width: _baseRadius * 1.4, color: const Color(0xFF334155)),
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
                child: const Icon(Icons.navigation, color: Colors.white, size: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _updateJoystick(Offset localPosition) {
    final center = _baseRadius;
    double dx = (localPosition.dx - center) / (_baseRadius - _knobRadius);
    double dy = (localPosition.dy - center) / (_baseRadius - _knobRadius);
    final dist = sqrt(dx * dx + dy * dy);
    if (dist > 1) { dx /= dist; dy /= dist; }
    setState(() { _joystickDx = dx; _joystickDy = dy; _joystickActive = true; });
    _notifyUpdate();
  }

  void _notifyUpdate() {
    if (_joystickActive && (_joystickDx != 0 || _joystickDy != 0)) {
      final bearing = atan2(_joystickDx, -_joystickDy) * 180 / pi;
      widget.onSimUpdate(bearing: bearing, speedMs: _simSpeed, isMoving: true);
    } else {
      widget.onSimUpdate(bearing: 0, speedMs: _simSpeed, isMoving: false);
    }
  }

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
  final double speed;
  const _SpeedPreset(this.label, this.speed);
}
