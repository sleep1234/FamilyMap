import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Circle;
import '../models/models.dart';
import '../services/api_service.dart';

/// 足迹管理页面 - 在地图上查看和管理保存的地点
class FootprintScreen extends StatefulWidget {
  final AppUser currentUser;
  final ApiService apiService;

  const FootprintScreen({
    super.key,
    required this.currentUser,
    required this.apiService,
  });

  @override
  State<FootprintScreen> createState() => _FootprintScreenState();
}

class _FootprintScreenState extends State<FootprintScreen> {
  List<Footprint> _footprints = [];
  bool _isLoading = true;
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    _loadFootprints();
  }

  Future<void> _loadFootprints() async {
    try {
      final fps = await widget.apiService.getFootprints(widget.currentUser.id);
      setState(() {
        _footprints = fps;
        _isLoading = false;
      });
      // 自动适配视图
      if (fps.isNotEmpty) {
        double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
        for (final f in fps) {
          if (f.latitude < minLat) minLat = f.latitude;
          if (f.latitude > maxLat) maxLat = f.latitude;
          if (f.longitude < minLng) minLng = f.longitude;
          if (f.longitude > maxLng) maxLng = f.longitude;
        }
        _mapController.move(
          LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2),
          12,
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addFootprint() async {
    final nameCtrl = TextEditingController();
    final catCtrl = TextEditingController(text: 'other');
    double? lat, lng;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('添加足迹'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '地点名称', hintText: '例如: 常去的咖啡店'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: catCtrl.text,
                decoration: const InputDecoration(labelText: '分类'),
                items: const [
                  DropdownMenuItem(value: 'home', child: Text('家')),
                  DropdownMenuItem(value: 'work', child: Text('公司')),
                  DropdownMenuItem(value: 'school', child: Text('学校')),
                  DropdownMenuItem(value: 'food', child: Text('美食')),
                  DropdownMenuItem(value: 'fun', child: Text('娱乐')),
                  DropdownMenuItem(value: 'other', child: Text('其他')),
                ],
                onChanged: (v) { if (v != null) catCtrl.text = v; },
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(labelText: '纬度', hintText: '留空则使用当前位置'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (v) => lat = double.tryParse(v),
              ),
              TextField(
                decoration: const InputDecoration(labelText: '经度', hintText: '留空则使用当前位置'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (v) => lng = double.tryParse(v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) return;
                Navigator.pop(ctx, {
                  'name': nameCtrl.text.trim(),
                  'category': catCtrl.text,
                  'lat': lat ?? 39.9042,
                  'lng': lng ?? 116.4074,
                });
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );

    if (result == null) return;

    try {
      await widget.apiService.createFootprint(
        widget.currentUser.id,
        result['name'],
        result['lat'],
        result['lng'],
        category: result['category'],
      );
      _loadFootprints();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('添加失败: $e')));
      }
    }
  }

  Future<void> _deleteFootprint(int id) async {
    try {
      await widget.apiService.deleteFootprint(id);
      _loadFootprints();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  String _categoryLabel(String cat) {
    const labels = {'home': '家', 'work': '公司', 'school': '学校', 'food': '美食', 'fun': '娱乐', 'other': '其他'};
    return labels[cat] ?? '其他';
  }

  IconData _categoryIcon(String cat) {
    const icons = {'home': Icons.home, 'work': Icons.business, 'school': Icons.school, 'food': Icons.restaurant, 'fun': Icons.sports_esports, 'other': Icons.place};
    return icons[cat] ?? Icons.place;
  }

  Color _categoryColor(String cat) {
    const colors = {'home': Color(0xFF10B981), 'work': Color(0xFF3B82F6), 'school': Color(0xFF8B5CF6), 'food': Color(0xFFF59E0B), 'fun': Color(0xFFEC4899), 'other': Color(0xFF64748B)};
    return colors[cat] ?? const Color(0xFF64748B);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的足迹')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 地图
                SizedBox(
                  height: 250,
                  child: FlutterMap(
                    mapController: _mapController,
                    options: const MapOptions(
                      initialCenter: LatLng(39.9042, 116.4074),
                      initialZoom: 12,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
                        subdomains: const ['1', '2', '3', '4'],
                        maxZoom: 18,
                      ),
                      MarkerLayer(
                        markers: _footprints.map((f) => Marker(
                          point: LatLng(f.latitude, f.longitude),
                          width: 40,
                          height: 40,
                          child: Icon(_categoryIcon(f.category), color: _categoryColor(f.category), size: 30),
                        )).toList(),
                      ),
                    ],
                  ),
                ),
                // 列表
                Expanded(
                  child: _footprints.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.explore, size: 48, color: Color(0xFFCBD5E1)),
                              const SizedBox(height: 8),
                              const Text('还没有保存足迹', style: TextStyle(color: Color(0xFF94A3B8))),
                              const SizedBox(height: 12),
                              ElevatedButton(onPressed: _addFootprint, child: const Text('添加足迹')),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: _footprints.length,
                          itemBuilder: (ctx, i) {
                            final f = _footprints[i];
                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: _categoryColor(f.category).withOpacity(0.15),
                                  child: Icon(_categoryIcon(f.category), color: _categoryColor(f.category), size: 20),
                                ),
                                title: Text(f.name),
                                subtitle: Text('${_categoryLabel(f.category)} · ${f.latitude.toStringAsFixed(4)}, ${f.longitude.toStringAsFixed(4)}'),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Color(0xFFEF4444)),
                                  onPressed: () => _deleteFootprint(f.id!),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addFootprint,
        child: const Icon(Icons.add_location_alt),
      ),
    );
  }
}
