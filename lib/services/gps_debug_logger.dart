import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

/// GPS调试日志条目
class GpsLogEntry {
  final DateTime time;
  final double lat;
  final double lng;
  final double accuracy;    // 米
  final double speed;       // m/s
  final double heading;     // 度
  final bool isMocked;      // 是否模拟位置
  final String? activity;   // 当前活动类型
  final String? note;       // 附加备注

  GpsLogEntry({
    required this.time,
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.speed,
    required this.heading,
    required this.isMocked,
    this.activity,
    this.note,
  });

  String toCsvLine() {
    return '${time.toIso8601String()},$lat,$lng,$accuracy,${speed.toStringAsFixed(2)},${heading.toStringAsFixed(1)},$isMocked,${activity ?? ""},${note ?? ""}';
  }
}

/// GPS调试日志记录器 - 全局单例
/// 开启后记录每条GPS信息，支持导出CSV
class GpsDebugLogger {
  GpsDebugLogger._();
  static final GpsDebugLogger instance = GpsDebugLogger._();

  /// 是否已开启调试
  bool enabled = false;

  /// 内存中最近200条日志
  final List<GpsLogEntry> _logs = [];
  static const int _maxLogs = 200;

  /// 当前GPS状态快照（给调试弹窗实时看）
  GpsLogEntry? currentSnapshot;

  /// GPS信号质量评估
  String get signalQuality {
    if (currentSnapshot == null) return '无信号';
    final acc = currentSnapshot!.accuracy;
    if (acc <= 10) return '极佳';
    if (acc <= 25) return '良好';
    if (acc <= 50) return '一般';
    if (acc <= 100) return '较差';
    return '很差';
  }

  /// 信号质量颜色
  int get signalColor {
    if (currentSnapshot == null) return 0xFFEF4444;
    final acc = currentSnapshot!.accuracy;
    if (acc <= 10) return 0xFF10B981;
    if (acc <= 25) return 0xFF22C55E;
    if (acc <= 50) return 0xFFF59E0B;
    if (acc <= 100) return 0xFFEF4444;
    return 0xFFDC2626;
  }

  /// 记录一条GPS日志
  void log(GpsLogEntry entry) {
    if (!enabled) return;
    currentSnapshot = entry;
    _logs.add(entry);
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }
  }

  /// 获取所有日志（只读）
  List<GpsLogEntry> get logs => List.unmodifiable(_logs);

  /// 清空日志
  void clear() {
    _logs.clear();
    currentSnapshot = null;
  }

  /// 导出CSV到文件，返回文件路径
  Future<String?> exportCsv() async {
    if (_logs.isEmpty) return null;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      final filename = 'gps_debug_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.csv';
      final file = File('${dir.path}/$filename');
      final lines = <String>[];
      lines.add('time,latitude,longitude,accuracy_m,speed_ms,heading_deg,is_mocked,activity,note');
      for (final e in _logs) {
        lines.add(e.toCsvLine());
      }
      await file.writeAsString(lines.join('\n'));
      return file.path;
    } catch (e) {
      debugPrint('[GpsDebug] 导出失败: $e');
      return null;
    }
  }
}
