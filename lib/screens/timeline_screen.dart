import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Circle;
import '../models/models.dart';
import '../services/api_service.dart';
import '../config.dart';

/// 时间线页面 - 查看某天的行程记录（地图为主 + 底部可拖拽时间线面板）
class TimelineScreen extends StatefulWidget {
  final AppUser currentUser;
  final ApiService apiService;

  const TimelineScreen({
    super.key,
    required this.currentUser,
    required this.apiService,
  });

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  DateTime _selectedDate = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
  );
  List<Stay> _stays = [];
  List<Map<String, dynamic>> _trackPoints = [];
  bool _isLoading = true;
  final MapController _mapController = MapController();

  // 底部面板拖拽
  double _panelHeight = 120; // 初始显示日期选择器 + 统计行
  static const double _panelPeek = 120;
  static const double _panelHalf = 320;
  static const double _panelFull = 520;
  double _dragStartY = 0;
  double _dragStartHeight = 0;

  // 选中的停留
  int? _selectedStayIndex;

  @override
  void initState() {
    super.initState();
    _loadTimeline();
  }

  Future<void> _loadTimeline() async {
    setState(() => _isLoading = true);
    try {
      final dateStr = _selectedDate.toIso8601String().split('T')[0];
      final results = await Future.wait([
        widget.apiService.getTimeline(widget.currentUser.id, date: dateStr),
        widget.apiService.getTrack(widget.currentUser.id, date: dateStr),
      ]);
      setState(() {
        _stays = results[0] as List<Stay>;
        _trackPoints = results[1] as List<Map<String, dynamic>>;
        _isLoading = false;
        _selectedStayIndex = null;
      });
      _fitMapToData();
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  /// 自动适配地图视图到轨迹和停留点
  void _fitMapToData() {
    final points = _getTrackLatLngs();
    final stayPoints = _stays
        .where((s) => s.latitude != null && s.longitude != null)
        .map((s) => _wgs84ToGcj02(s.latitude!, s.longitude!))
        .toList();
    final allPoints = [...points, ...stayPoints];
    if (allPoints.isEmpty) return;

    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in allPoints) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final center = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
    // 根据范围估算缩放级别
    final latDiff = maxLat - minLat;
    final lngDiff = maxLng - minLng;
    final maxDiff = max(latDiff, lngDiff);
    double zoom = 13;
    if (maxDiff > 0.5) zoom = 10;
    else if (maxDiff > 0.1) zoom = 12;
    else if (maxDiff > 0.02) zoom = 14;

    _mapController.move(center, zoom);
  }

  void _changeDay(int offset) {
    setState(() => _selectedDate = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day + offset,
    ));
    _loadTimeline();
  }

  String _formatTime(DateTime? t) {
    if (t == null) return '--:--';
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  String _weekdayLabel(DateTime d) {
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return labels[d.weekday - 1];
  }

  /// 统一格式化停留时长：xx天xx时xx分
  String _formatDuration(int minutes) {
    if (minutes <= 0) return '0分';
    final d = minutes ~/ (24 * 60);
    final h = (minutes % (24 * 60)) ~/ 60;
    final m = minutes % 60;

    final parts = <String>[];
    if (d > 0) parts.add('${d}天');
    if (h > 0) parts.add('${h}时');
    if (m > 0) parts.add('${m}分');
    // 如果天和时都为0，至少显示分钟
    if (parts.isEmpty) parts.add('${minutes}分');
    return parts.join('');
  }

  /// 将轨迹点转为 Polyline 的坐标列表
  List<LatLng> _getTrackLatLngs() {
    return _trackPoints
        .where((p) => p['latitude'] != null && p['longitude'] != null)
        .map((p) => _wgs84ToGcj02(
              (p['latitude'] as num).toDouble(),
              (p['longitude'] as num).toDouble(),
            ))
        .toList();
  }

  void _onStayTap(int index) {
    final stay = _stays[index];
    if (stay.latitude != null && stay.longitude != null) {
      final gcjPos = _wgs84ToGcj02(stay.latitude!, stay.longitude!);
      _mapController.move(gcjPos, 16);
      setState(() => _selectedStayIndex = index);
    }
  }

  /// 面板吸附到最近档位
  void _snapPanel() {
    final distPeek = (_panelHeight - _panelPeek).abs();
    final distHalf = (_panelHeight - _panelHalf).abs();
    final distFull = (_panelHeight - _panelFull).abs();
    double target;
    if (distPeek <= distHalf && distPeek <= distFull) {
      target = _panelPeek;
    } else if (distHalf <= distFull) {
      target = _panelHalf;
    } else {
      target = _panelFull;
    }
    setState(() => _panelHeight = target);
  }

  @override
  Widget build(BuildContext context) {
    final trackPts = _getTrackLatLngs();
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      body: Stack(
        children: [
          // ===== 全屏地图 =====
          Positioned.fill(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: const LatLng(39.9042, 116.4074),
                initialZoom: 12,
              ),
              children: [
                TileLayer(
                  urlTemplate: '${AppConfig.httpBaseUrl}/api/tiles/{z}/{x}/{y}',
                  maxZoom: 18,
                ),
                // 轨迹线
                if (trackPts.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: trackPts,
                        color: const Color(0xFF4F46E5).withOpacity(0.7),
                        strokeWidth: 4,
                      ),
                    ],
                  ),
                // 停留点标记
                MarkerLayer(
                  markers: _stays.asMap().entries
                      .where((e) => e.value.latitude != null && e.value.longitude != null)
                      .map((entry) {
                        final i = entry.key;
                        final s = entry.value;
                        final isActive = s.endedAt == null;
                        final isSelected = _selectedStayIndex == i;
                        return Marker(
                          point: _wgs84ToGcj02(s.latitude!, s.longitude!),
                          width: isSelected ? 36 : 28,
                          height: isSelected ? 36 : 28,
                          child: GestureDetector(
                            onTap: () => _onStayTap(i),
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isSelected
                                    ? const Color(0xFFEF4444)
                                    : isActive
                                        ? const Color(0xFF10B981)
                                        : const Color(0xFF4F46E5),
                                border: Border.all(color: Colors.white, width: isSelected ? 3 : 2),
                                boxShadow: isSelected
                                    ? [BoxShadow(color: const Color(0xFFEF4444).withOpacity(0.4), blurRadius: 8)]
                                    : null,
                              ),
                              child: Center(
                                child: Text(
                                  '${i + 1}',
                                  style: TextStyle(
                                    color: Colors.white, fontSize: isSelected ? 13 : 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  textScaleFactor: 1.0,
                                ),
                              ),
                            ),
                          ),
                        );
                      })
                      .toList(),
                ),
              ],
            ),
          ),

          // ===== 顶部日期选择器（半透明浮动） =====
          Positioned(
            top: MediaQuery.of(context).padding.top,
            left: 0, right: 0,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.92),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8)],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left, size: 20),
                      onPressed: () => _changeDay(-1),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                    Text(
                      '${_selectedDate.month}月${_selectedDate.day}日 ${_weekdayLabel(_selectedDate)}',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right, size: 20),
                      onPressed: _selectedDate.isBefore(DateTime.now()) ? () => _changeDay(1) : null,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                    TextButton(
                      onPressed: () { setState(() => _selectedDate = DateTime.now()); _loadTimeline(); },
                      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: Size.zero),
                      child: const Text('今天', style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ===== 底部可拖拽时间线面板 =====
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: GestureDetector(
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
                _snapPanel();
              },
              child: Container(
                height: _panelHeight,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))],
                ),
                child: Column(
                  children: [
                    // 拖拽手柄（点击也可以循环切换档位）
                    GestureDetector(
                      onTap: () {
                        if (_panelHeight < (_panelPeek + _panelHalf) / 2) {
                          setState(() => _panelHeight = _panelHalf);
                        } else if (_panelHeight < (_panelHalf + _panelFull) / 2) {
                          setState(() => _panelHeight = _panelFull);
                        } else {
                          setState(() => _panelHeight = _panelPeek);
                        }
                      },
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        width: 40, height: 4,
                        decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    // 统计栏
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${_stays.length}个停留',
                            style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                          ),
                          if (trackPts.isNotEmpty)
                            Text(
                              '${trackPts.length}个轨迹点',
                              style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    // 时间线列表
                    Expanded(
                      child: _isLoading
                          ? const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))
                          : _stays.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.timeline, size: 36, color: Color(0xFFCBD5E1)),
                                      const SizedBox(height: 6),
                                      Text(
                                        '${_selectedDate.month}月${_selectedDate.day}日没有停留记录',
                                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                                      ),
                                    ],
                                  ),
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  itemCount: _stays.length,
                                  itemBuilder: (ctx, i) => _buildTimelineItem(_stays[i], i),
                                ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineItem(Stay stay, int index) {
    final isActive = stay.endedAt == null;
    final duration = stay.durationMinutes ?? 0;
    final startedAt = stay.startedAt;
    final endedAt = stay.endedAt;
    final isSelected = _selectedStayIndex == index;

    return GestureDetector(
      onTap: () => _onStayTap(index),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 44,
              child: Column(
                children: [
                  Text(_formatTime(startedAt), style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                  if (endedAt != null)
                    Text(_formatTime(endedAt), style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
                ],
              ),
            ),
            SizedBox(
              width: 22,
              child: Column(
                children: [
                  Container(
                    width: 12, height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isSelected
                          ? const Color(0xFFEF4444)
                          : isActive
                              ? const Color(0xFF10B981)
                              : const Color(0xFF4F46E5),
                      border: isSelected
                          ? Border.all(color: const Color(0xFFEF4444).withOpacity(0.3), width: 3)
                          : isActive
                              ? Border.all(color: const Color(0xFF10B981).withOpacity(0.3), width: 3)
                              : null,
                    ),
                    child: Center(
                      child: Text('${index + 1}', style: const TextStyle(color: Colors.white, fontSize: 7, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  if (index < _stays.length - 1)
                    Expanded(child: Container(width: 2, color: const Color(0xFFE2E8F0))),
                ],
              ),
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFFFEF2F2)
                      : isActive
                          ? const Color(0xFFECFDF5)
                          : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(8),
                  border: isSelected
                      ? Border.all(color: const Color(0xFFEF4444).withOpacity(0.3))
                      : isActive
                          ? Border.all(color: const Color(0xFF10B981).withOpacity(0.3))
                          : Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isSelected ? Icons.location_on : isActive ? Icons.location_on : Icons.location_on_outlined,
                          size: 14,
                          color: isSelected ? const Color(0xFFEF4444) : isActive ? const Color(0xFF10B981) : const Color(0xFF64748B),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            stay.address?.isNotEmpty == true ? stay.address! : '未知地点',
                            style: TextStyle(fontSize: 13, fontWeight: isSelected || isActive ? FontWeight.w600 : FontWeight.w500),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (duration > 0 || isActive) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFFEF4444).withOpacity(0.08)
                              : isActive
                                  ? const Color(0xFF10B981).withOpacity(0.1)
                                  : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          isActive
                              ? '停留中 · ${_formatDuration(DateTime.now().difference(startedAt ?? DateTime.now()).inMinutes)}'
                              : _formatDuration(duration),
                          style: TextStyle(
                            fontSize: 11,
                            color: isSelected
                                ? const Color(0xFFEF4444)
                                : isActive
                                    ? const Color(0xFF10B981)
                                    : const Color(0xFF64748B),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// WGS-84 转 GCJ-02
LatLng _wgs84ToGcj02(double wgsLat, double wgsLng) {
  const double a = 6378245.0;
  const double ee = 0.00669342162296594323;
  if (wgsLng < 72.004 || wgsLng > 137.8347 || wgsLat < 0.8293 || wgsLat > 55.8271) return LatLng(wgsLat, wgsLng);
  double dLat = _tLat(wgsLng - 105.0, wgsLat - 35.0);
  double dLng = _tLng(wgsLng - 105.0, wgsLat - 35.0);
  double radLat = wgsLat / 180.0 * 3.14159265358979323846;
  double magic = 1 - ee * sin(radLat) * sin(radLat);
  double sqrtMagic = sqrt(magic);
  dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * 3.14159265358979323846);
  dLng = (dLng * 180.0) / (a / sqrtMagic * cos(radLat) * 3.14159265358979323846);
  return LatLng(wgsLat + dLat, wgsLng + dLng);
}
double _tLat(double x, double y) {
  double r = -100+2*x+3*y+.2*y*y+.1*x*y+.2*sqrt(x.abs());
  r += (20*sin(6*x*3.14159265358979323846)+20*sin(2*x*3.14159265358979323846))*2/3;
  r += (20*sin(y*3.14159265358979323846)+40*sin(y/3*3.14159265358979323846))*2/3;
  r += (160*sin(y/12*3.14159265358979323846)+320*sin(y*3.14159265358979323846/30))*2/3;
  return r;
}
double _tLng(double x, double y) {
  double r = 300+x+2*y+.1*x*x+.1*x*y+.1*sqrt(x.abs());
  r += (20*sin(6*x*3.14159265358979323846)+20*sin(2*x*3.14159265358979323846))*2/3;
  r += (20*sin(x*3.14159265358979323846)+40*sin(x/3*3.14159265358979323846))*2/3;
  r += (150*sin(x/12*3.14159265358979323846)+300*sin(x/30*3.14159265358979323846))*2/3;
  return r;
}
