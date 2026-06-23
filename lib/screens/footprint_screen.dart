import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Circle;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import '../services/api_service.dart';
import '../config.dart';

const _amapKey = String.fromEnvironment('AMAP_KEY', defaultValue: '');

/// 高德POI搜索结果
class _PoiItem {
  final String name;
  final String address;
  final double latitude;
  final double longitude;
  _PoiItem({required this.name, required this.address, required this.latitude, required this.longitude});
}

/// 足迹管理页面 - 全屏地图 + 长按选点/搜索位置添加足迹 + 底部可拖拽面板
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

  // 底部面板拖拽
  double _panelHeight = 80;
  static const double _panelPeek = 80;
  static const double _panelHalf = 280;
  static const double _panelFull = 480;
  double _dragStartY = 0;
  double _dragStartHeight = 0;

  // 选中的足迹
  int? _selectedFootprintId;

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
        _selectedFootprintId = null;
      });
      _fitMapToFootprints();
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  void _fitMapToFootprints() {
    if (_footprints.isEmpty) {
      _locateToCurrentPosition();
      return;
    }
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final f in _footprints) {
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

  Future<void> _locateToCurrentPosition() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 5),
        ),
      );
      _mapController.move(LatLng(pos.latitude, pos.longitude), 14);
    } catch (_) {}
  }

  // ==================== 高德POI搜索 ====================

  Future<List<_PoiItem>> _searchPoi(String keyword) async {
    try {
      final url = Uri.parse(
        'https://restapi.amap.com/v3/place/text?keywords=${Uri.encodeComponent(keyword)}'
        '&key=$_amapKey&offset=10&page=1&extensions=base',
      );
      final resp = await http.get(url);
      if (resp.statusCode != 200) return [];
      final data = json.decode(resp.body);
      if (data['status'] != '1') return [];
      final list = data['pois'] as List? ?? [];
      return list.map<_PoiItem>((p) {
        final loc = (p['location'] ?? '') as String;
        final parts = loc.split(',');
        return _PoiItem(
          name: p['name'] ?? '',
          address: p['address'] ?? p['city'] ?? '',
          latitude: parts.length == 2 ? double.tryParse(parts[1]) ?? 0 : 0,
          longitude: parts.length == 2 ? double.tryParse(parts[0]) ?? 0 : 0,
        );
      }).where((p) => p.latitude != 0 && p.longitude != 0).toList();
    } catch (_) {
      return [];
    }
  }

  // ==================== 添加足迹对话框 ====================

  /// 打开添加足迹对话框（支持搜索位置 + 长按地图）
  Future<void> _showAddDialog({LatLng? longPressEvent}) async {
    final nameCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    String category = 'other';
    LatLng? selectedPoint = longPressEvent;
    String? selectedAddress;
    bool isSearching = false;
    List<_PoiItem> searchResults = [];
    final searchCtrl = TextEditingController();

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('添加足迹'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ---- 位置搜索栏 ----
                  TextField(
                    controller: searchCtrl,
                    decoration: InputDecoration(
                      labelText: '搜索地点',
                      hintText: '输入地名、地址搜索',
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: searchCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                searchCtrl.clear();
                                setDialogState(() { searchResults = []; });
                              },
                            )
                          : null,
                    ),
                    textInputAction: TextInputAction.search,
                    onChanged: (_) => setDialogState(() {}),
                    onSubmitted: (v) async {
                      if (v.trim().isEmpty) return;
                      setDialogState(() => isSearching = true);
                      final results = await _searchPoi(v.trim());
                      setDialogState(() { searchResults = results; isSearching = false; });
                    },
                  ),
                  const SizedBox(height: 6),

                  // 搜索结果列表
                  if (isSearching)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                    )
                  else if (searchResults.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: searchResults.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final poi = searchResults[i];
                          final isSelected = selectedPoint != null &&
                              (poi.latitude - selectedPoint!.latitude).abs() < 0.0001 &&
                              (poi.longitude - selectedPoint!.longitude).abs() < 0.0001;
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            leading: Icon(Icons.place, size: 18, color: isSelected ? const Color(0xFF3B82F6) : const Color(0xFF94A3B8)),
                            title: Text(poi.name, style: TextStyle(fontSize: 13, fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal)),
                            subtitle: Text(poi.address, style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)), maxLines: 1, overflow: TextOverflow.ellipsis),
                            selected: isSelected,
                            selectedTileColor: const Color(0xFF3B82F6).withOpacity(0.06),
                            onTap: () {
                              // 选中POI → 自动填充名称和坐标
                              nameCtrl.text = poi.name;
                              setDialogState(() {
                                selectedPoint = LatLng(poi.latitude, poi.longitude);
                                selectedAddress = poi.address;
                              });
                            },
                          );
                        },
                      ),
                    ),

                  // 当前选中位置的指示
                  if (selectedPoint != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0F9FF),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFBAE6FD)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.location_on, size: 16, color: Color(0xFF3B82F6)),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              selectedAddress ??
                                  '${selectedPoint!.latitude.toStringAsFixed(5)}, ${selectedPoint!.longitude.toStringAsFixed(5)}',
                              style: const TextStyle(fontSize: 12, color: Color(0xFF0369A1)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    Text(
                      longPressEvent != null ? '长按选择的位置' : '请搜索或长按地图选择位置',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                    ),
                  ],

                  const SizedBox(height: 12),

                  // ---- 地点名称 ----
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '地点名称',
                      hintText: '例如: 常去的咖啡店',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ---- 分类 ----
                  DropdownButtonFormField<String>(
                    value: category,
                    decoration: const InputDecoration(labelText: '分类', isDense: true),
                    items: const [
                      DropdownMenuItem(value: 'home', child: Text('家')),
                      DropdownMenuItem(value: 'work', child: Text('公司')),
                      DropdownMenuItem(value: 'school', child: Text('学校')),
                      DropdownMenuItem(value: 'food', child: Text('美食')),
                      DropdownMenuItem(value: 'fun', child: Text('娱乐')),
                      DropdownMenuItem(value: 'other', child: Text('其他')),
                    ],
                    onChanged: (v) { if (v != null) setDialogState(() => category = v); },
                  ),
                  const SizedBox(height: 12),

                  // ---- 备注 ----
                  TextField(
                    controller: noteCtrl,
                    decoration: const InputDecoration(
                      labelText: '备注',
                      hintText: '记录在这里的经历...',
                      isDense: true,
                      alignLabelWithHint: true,
                    ),
                    maxLines: 3,
                    minLines: 2,
                    maxLength: 500,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              TextButton(
                onPressed: () {
                  if (nameCtrl.text.trim().isEmpty) return;
                  if (selectedPoint == null && longPressEvent != null) {
                    selectedPoint = longPressEvent;
                  }
                  if (selectedPoint == null) return;
                  Navigator.pop(ctx, {
                    'name': nameCtrl.text.trim(),
                    'category': category,
                    'lat': selectedPoint!.latitude,
                    'lng': selectedPoint!.longitude,
                    'note': noteCtrl.text.trim(),
                  });
                },
                child: const Text('添加'),
              ),
            ],
          );
        },
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
        note: result['note'] ?? '',
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

  void _onFootprintTap(Footprint f) {
    setState(() => _selectedFootprintId = f.id);
    _mapController.move(LatLng(f.latitude, f.longitude), 16);
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
                onLongPress: (tapPosition, point) => _showAddDialog(longPressEvent: point),
              ),
              children: [
                TileLayer(
                  urlTemplate: '${AppConfig.httpBaseUrl}/api/tiles/{z}/{x}/{y}',
                  maxZoom: 18,
                ),
                MarkerLayer(
                  markers: _footprints.map((f) {
                    final isSelected = _selectedFootprintId == f.id;
                    final color = _categoryColor(f.category);
                    return Marker(
                      point: LatLng(f.latitude, f.longitude),
                      width: isSelected ? 44 : 36,
                      height: isSelected ? 44 : 36,
                      child: GestureDetector(
                        onTap: () => _onFootprintTap(f),
                        child: Container(
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: isSelected ? 3 : 2),
                            boxShadow: isSelected
                                ? [BoxShadow(color: color.withOpacity(0.4), blurRadius: 8)]
                                : [BoxShadow(color: Colors.black12, blurRadius: 4)],
                          ),
                          child: Icon(
                            _categoryIcon(f.category),
                            color: Colors.white,
                            size: isSelected ? 22 : 18,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),

          // ===== 顶部操作栏 =====
          Positioned(
            top: MediaQuery.of(context).padding.top,
            left: 0, right: 0,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.92),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6)],
                ),
                child: Row(
                  children: [
                    Icon(Icons.touch_app, size: 16, color: Colors.grey.shade600),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '长按地图或搜索添加足迹',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                      ),
                    ),
                    if (_footprints.isNotEmpty)
                      Text(
                        '${_footprints.length}个足迹',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                        textScaleFactor: 1.0,
                      ),
                    const SizedBox(width: 8),
                    // 搜索添加按钮
                    Material(
                      color: const Color(0xFF3B82F6),
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _showAddDialog(),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_location_alt, size: 16, color: Colors.white),
                              SizedBox(width: 4),
                              Text('搜索添加', style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w500)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ===== 底部可拖拽足迹列表面板 =====
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
                    // 标题栏
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('我的足迹', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                          if (_footprints.isNotEmpty)
                            Text(
                              _footprints.length.toString(),
                              style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    // 足迹列表
                    Expanded(
                      child: _isLoading
                          ? const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))
                          : _footprints.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.explore, size: 36, color: Color(0xFFCBD5E1)),
                                      const SizedBox(height: 6),
                                      const Text('还没有保存足迹', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                                      const SizedBox(height: 4),
                                      const Text('长按地图或搜索添加', style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
                                    ],
                                  ),
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  itemCount: _footprints.length,
                                  itemBuilder: (ctx, i) {
                                    final f = _footprints[i];
                                    final isSelected = _selectedFootprintId == f.id;
                                    final color = _categoryColor(f.category);
                                    return Card(
                                      margin: const EdgeInsets.only(bottom: 6),
                                      elevation: isSelected ? 2 : 0,
                                      color: isSelected ? color.withOpacity(0.06) : null,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        side: isSelected
                                            ? BorderSide(color: color.withOpacity(0.3))
                                            : BorderSide(color: const Color(0xFFE2E8F0)),
                                      ),
                                      child: ListTile(
                                        dense: true,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                                        leading: CircleAvatar(
                                          radius: 16,
                                          backgroundColor: color.withOpacity(0.15),
                                          child: Icon(_categoryIcon(f.category), color: color, size: 18),
                                        ),
                                        title: Text(f.name, style: TextStyle(fontSize: 14, fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500)),
                                        subtitle: Text(
                                          f.note.isNotEmpty
                                              ? '${_categoryLabel(f.category)} · ${f.note}'
                                              : _categoryLabel(f.category),
                                          style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        trailing: IconButton(
                                          icon: const Icon(Icons.delete_outline, color: Color(0xFFEF4444), size: 18),
                                          onPressed: () => _deleteFootprint(f.id!),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                        ),
                                        onTap: () => _onFootprintTap(f),
                                      ),
                                    );
                                  },
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
}
