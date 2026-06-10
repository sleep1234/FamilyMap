import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Circle;
import '../models/models.dart';
import '../services/api_service.dart';

/// 时间线页面 - 查看某天的行程记录（停留+移动+轨迹线）
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
  DateTime _selectedDate = DateTime.now();
  List<Stay> _stays = [];
  List<Map<String, dynamic>> _trackPoints = [];
  bool _isLoading = true;
  bool _showMap = true; // 是否显示地图

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
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  void _changeDay(int offset) {
    setState(() => _selectedDate = _selectedDate.add(Duration(days: offset)));
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

  @override
  Widget build(BuildContext context) {
    final trackPts = _getTrackLatLngs();
    return Scaffold(
      appBar: AppBar(title: const Text('行程时间线')),
      body: Column(
        children: [
          _buildDateSelector(),
          const Divider(height: 1),
          // 轨迹地图（可折叠）
          if (_showMap && trackPts.length >= 2)
            SizedBox(
              height: 200,
              child: FlutterMap(
                options: MapOptions(
                  initialCenter: trackPts.first,
                  initialZoom: 13,
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
                    subdomains: const ['1', '2', '3', '4'],
                    maxZoom: 18,
                  ),
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: trackPts,
                        color: const Color(0xFF4F46E5),
                        strokeWidth: 3,
                      ),
                    ],
                  ),
                  // 停留点标记
                  MarkerLayer(
                    markers: _stays
                        .where((s) => s.latitude != null && s.longitude != null)
                        .map((s) => Marker(
                              point: _wgs84ToGcj02(s.latitude!, s.longitude!),
                              width: 24,
                              height: 24,
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: s.endedAt == null ? const Color(0xFF10B981) : const Color(0xFF4F46E5),
                                  border: Border.all(color: Colors.white, width: 2),
                                ),
                                child: const Icon(Icons.location_on, color: Colors.white, size: 12),
                              ),
                            ))
                        .toList(),
                  ),
                ],
              ),
            ),
          // 地图折叠按钮
          if (trackPts.length >= 2)
            GestureDetector(
              onTap: () => setState(() => _showMap = !_showMap),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                color: const Color(0xFFF8FAFC),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_showMap ? Icons.expand_less : Icons.expand_more, size: 16, color: const Color(0xFF64748B)),
                    const SizedBox(width: 4),
                    Text(
                      '${trackPts.length}个轨迹点 · ${_stays.length}个停留',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                    ),
                  ],
                ),
              ),
            ),
          // 时间线列表
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _stays.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.timeline, size: 48, color: Color(0xFFCBD5E1)),
                            const SizedBox(height: 8),
                            Text(
                              '${_selectedDate.month}月${_selectedDate.day}日没有停留记录',
                              style: const TextStyle(color: Color(0xFF94A3B8)),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _stays.length,
                        itemBuilder: (ctx, i) => _buildTimelineItem(_stays[i], i),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _changeDay(-1)),
          Text(
            '${_selectedDate.month}月${_selectedDate.day}日 ${_weekdayLabel(_selectedDate)}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _selectedDate.isBefore(DateTime.now()) ? () => _changeDay(1) : null,
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () { setState(() => _selectedDate = DateTime.now()); _loadTimeline(); },
            child: const Text('今天'),
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

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: Column(
              children: [
                Text(_formatTime(startedAt), style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                if (endedAt != null)
                  Text(_formatTime(endedAt), style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
              ],
            ),
          ),
          SizedBox(
            width: 24,
            child: Column(
              children: [
                Container(
                  width: 12, height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive ? const Color(0xFF10B981) : const Color(0xFF4F46E5),
                    border: isActive ? Border.all(color: const Color(0xFF10B981).withOpacity(0.3), width: 3) : null,
                  ),
                ),
                if (index < _stays.length - 1)
                  Expanded(child: Container(width: 2, color: const Color(0xFFE2E8F0))),
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isActive ? const Color(0xFFECFDF5) : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: isActive ? Border.all(color: const Color(0xFF10B981).withOpacity(0.3)) : Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(isActive ? Icons.location_on : Icons.location_on_outlined, size: 16,
                        color: isActive ? const Color(0xFF10B981) : const Color(0xFF64748B)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          stay.address?.isNotEmpty == true ? stay.address! : '未知地点',
                          style: TextStyle(fontSize: 14, fontWeight: isActive ? FontWeight.w600 : FontWeight.w500),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (duration > 0 || isActive) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: isActive ? const Color(0xFF10B981).withOpacity(0.1) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isActive
                            ? '停留中 · ${DateTime.now().difference(startedAt ?? DateTime.now()).inMinutes}分钟'
                            : stay.durationText,
                        style: TextStyle(fontSize: 12, color: isActive ? const Color(0xFF10B981) : const Color(0xFF64748B)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// WGS-84 转 GCJ-02（与 map_screen 中相同的函数）
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
