import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/gps_debug_logger.dart';

/// 设置/隐私页面
class SettingsScreen extends StatefulWidget {
  final AppUser currentUser;
  final ApiService apiService;
  final bool darkMode;
  final Function(bool) onDarkModeChanged;

  const SettingsScreen({
    super.key,
    required this.currentUser,
    required this.apiService,
    this.darkMode = false,
    required this.onDarkModeChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  UserSettings? _settings;
  bool _isLoading = true;
  String _ghostMode = 'off';
  bool _gpsDebugEnabled = false; // GPS调试开关

  // 轨迹皮肤选项
  static final _trailSkins = [
    {'id': 'default', 'name': '默认', 'icon': Icons.auto_awesome},
    {'id': 'fire', 'name': '火焰', 'icon': Icons.local_fire_department},
    {'id': 'ice', 'name': '冰雪', 'icon': Icons.ac_unit},
    {'id': 'rainbow', 'name': '彩虹', 'icon': Icons.color_lens},
    {'id': 'galaxy', 'name': '星河', 'icon': Icons.stars},
  ];

  @override
  void initState() {
    super.initState();
    _ghostMode = widget.currentUser.ghostMode;
    _loadSettings();
    _loadGpsDebugFlag();
  }

  Future<void> _loadGpsDebugFlag() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _gpsDebugEnabled = prefs.getBool('gps_debug') ?? false);
  }

  Future<void> _loadSettings() async {
    try {
      final s = await widget.apiService.getUserSettings(widget.currentUser.id);
      setState(() {
        _settings = s;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _updateSetting(String key, dynamic value) async {
    try {
      await widget.apiService.updateUserSettings(widget.currentUser.id, {key: value});
      await _loadSettings();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
      }
    }
  }

  Future<void> _updateGhostMode(String mode) async {
    try {
      await widget.apiService.updateUser(widget.currentUser.id, {'ghost_mode': mode});
      setState(() => _ghostMode = mode);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
      }
    }
  }

  Future<void> _updateMood(String mood) async {
    try {
      await widget.apiService.updateUser(widget.currentUser.id, {'mood': mood});
    } catch (_) {}
  }

  Future<void> _toggleSleeping(bool sleeping) async {
    try {
      await widget.apiService.updateUser(widget.currentUser.id, {'is_sleeping': sleeping ? 1 : 0});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // === 个人信息 ===
                _sectionHeader('个人信息'),
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _parseColor(widget.currentUser.avatarColor),
                    child: Text(widget.currentUser.name[0].toUpperCase(), style: const TextStyle(color: Colors.white)),
                  ),
                  title: Text(widget.currentUser.name),
                  subtitle: Text('ID: ${widget.currentUser.id.substring(0, 10)}...'),
                ),

                // 心情
                ListTile(
                  leading: const Icon(Icons.mood),
                  title: const Text('心情'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showMoodDialog(),
                ),

                // 睡眠状态
                SwitchListTile(
                  secondary: const Icon(Icons.bedtime),
                  title: const Text('睡眠模式'),
                  subtitle: const Text('开启后，圈子成员能看到你在睡觉'),
                  value: widget.currentUser.isSleeping,
                  onChanged: _toggleSleeping,
                ),

                const Divider(),

                // === 隐私设置 ===
                _sectionHeader('隐私保护'),
                
                // 幽灵模式
                ListTile(
                  leading: const Icon(Icons.visibility_off),
                  title: const Text('幽灵模式'),
                  subtitle: Text(_ghostModeLabel(_ghostMode)),
                  onTap: () => _showGhostModePicker(),
                ),

                // 模糊位置
                SwitchListTile(
                  secondary: const Icon(Icons.blur_on),
                  title: const Text('模糊位置'),
                  subtitle: const Text('在真实位置附近随机偏移约500米'),
                  value: _settings?.blurLocation ?? false,
                  onChanged: (v) => _updateSetting('blur_location', v ? 1 : 0),
                ),

                // 暂停共享
                SwitchListTile(
                  secondary: const Icon(Icons.pause_circle_outline),
                  title: const Text('暂停位置共享'),
                  subtitle: const Text('其他人将看不到你的实时位置'),
                  value: _settings?.sharePaused ?? false,
                  onChanged: (v) => _updateSetting('share_paused', v ? 1 : 0),
                ),

                const Divider(),

                // === 外观 ===
                _sectionHeader('外观与个性化'),

                // 暗色模式
                SwitchListTile(
                  secondary: const Icon(Icons.dark_mode),
                  title: const Text('深色模式'),
                  value: _settings?.darkMode ?? widget.darkMode,
                  onChanged: (v) {
                    _updateSetting('dark_mode', v ? 1 : 0);
                    widget.onDarkModeChanged(v); // 立即通知全局主题切换
                  },
                ),

                // 轨迹皮肤
                ListTile(
                  leading: Icon(_trailSkins.firstWhere(
                    (s) => s['id'] == (_settings?.trailSkin ?? 'default'),
                    orElse: () => _trailSkins[0],
                  )['icon'] as IconData),
                  title: const Text('轨迹皮肤'),
                  subtitle: Text(_trailSkins.firstWhere(
                    (s) => s['id'] == (_settings?.trailSkin ?? 'default'),
                    orElse: () => _trailSkins[0],
                  )['name'] as String),
                  onTap: () => _showTrailSkinPicker(),
                ),

                // 昵称颜色
                ListTile(
                  leading: const Icon(Icons.palette),
                  title: const Text('昵称颜色'),
                  trailing: _settings?.nicknameColor != null && _settings!.nicknameColor.isNotEmpty
                      ? CircleAvatar(radius: 10, backgroundColor: _parseColor(_settings!.nicknameColor))
                      : const Text('默认', style: TextStyle(color: Color(0xFF94A3B8))),
                  onTap: () => _showNicknameColorPicker(),
                ),

                const Divider(),

                // === 安全 ===
                _sectionHeader('安全与紧急'),

                // 4.3 紧急联系人
                ListTile(
                  leading: const Icon(Icons.emergency),
                  title: const Text('紧急联系人'),
                  subtitle: const Text('SOS时自动通知的联系人'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showEmergencyContacts(),
                ),

                // 4.8 轨迹导出
                ListTile(
                  leading: const Icon(Icons.download),
                  title: const Text('导出我的轨迹'),
                  subtitle: const Text('导出今天GPS轨迹为GPX格式'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _exportMyGpx(),
                ),

                const Divider(),

                // === 调试 ===
                _sectionHeader('调试'),

                // GPS调试开关
                SwitchListTile(
                  secondary: const Icon(Icons.bug_report),
                  title: const Text('GPS调试模式'),
                  subtitle: const Text('记录GPS日志并显示实时调试信息'),
                  value: _gpsDebugEnabled,
                  onChanged: (v) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('gps_debug', v);
                    GpsDebugLogger.instance.enabled = v;
                    if (!v) GpsDebugLogger.instance.clear();
                    setState(() => _gpsDebugEnabled = v);
                  },
                ),

                // 模拟驾驶开关
                SwitchListTile(
                  secondary: const Icon(Icons.directions_car),
                  title: const Text('模拟驾驶'),
                  subtitle: const Text('用摇杆模拟移动，室内测试拖尾和测速'),
                  value: false,
                  onChanged: (v) {
                    // 返回地图页时自动处理
                    Navigator.pop(context, v ? 'start_sim' : null);
                  },
                ),

                // GPS日志导出（仅调试开启时显示）
                if (_gpsDebugEnabled)
                  ListTile(
                    leading: const Icon(Icons.upload_file),
                    title: const Text('导出GPS日志'),
                    subtitle: Text('已记录 ${GpsDebugLogger.instance.logs.length} 条'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final path = await GpsDebugLogger.instance.exportCsv();
                      if (path != null && mounted) {
                        await Clipboard.setData(ClipboardData(text: path));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已导出到: $path（路径已复制）')),
                        );
                      } else if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('暂无日志可导出')),
                        );
                      }
                    },
                  ),

                if (_gpsDebugEnabled)
                  ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: const Text('清除GPS日志'),
                    onTap: () {
                      GpsDebugLogger.instance.clear();
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('GPS日志已清除')),
                      );
                    },
                  ),

                const Divider(),
                _sectionHeader('关于'),
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('FamilyMap'),
                  subtitle: Text('v0.1.0 - 家人朋友实时位置共享'),
                ),
              ],
            ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFF64748B),
        ),
      ),
    );
  }

  String _ghostModeLabel(String mode) {
    switch (mode) {
      case 'invisible': return '完全隐身 - 其他人看不到你';
      case 'blur': return '模糊 - 位置有偏移';
      default: return '关闭 - 正常共享';
    }
  }

  void _showGhostModePicker() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(padding: EdgeInsets.all(16), child: Text('幽灵模式', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            RadioListTile<String>(
              title: const Text('关闭'),
              subtitle: const Text('正常共享位置'),
              value: 'off', groupValue: _ghostMode,
              onChanged: (v) { Navigator.pop(ctx); if (v != null) _updateGhostMode(v); },
            ),
            RadioListTile<String>(
              title: const Text('模糊'),
              subtitle: const Text('位置有约500米偏移'),
              value: 'blur', groupValue: _ghostMode,
              onChanged: (v) { Navigator.pop(ctx); if (v != null) _updateGhostMode(v); },
            ),
            RadioListTile<String>(
              title: const Text('完全隐身'),
              subtitle: const Text('其他人完全看不到你的位置'),
              value: 'invisible', groupValue: _ghostMode,
              onChanged: (v) { Navigator.pop(ctx); if (v != null) _updateGhostMode(v); },
            ),
          ],
        ),
      ),
    );
  }

  void _showMoodDialog() {
    final moods = ['开心', '放松', '忙碌', '疲惫', '难过', '兴奋', '平静', '焦虑'];
    final ctrl = TextEditingController(text: widget.currentUser.mood ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置心情'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: ctrl, decoration: const InputDecoration(hintText: '输入心情...')),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: moods.map((m) => ActionChip(
                label: Text(m),
                onPressed: () { ctrl.text = m; },
              )).toList(),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () { _updateMood(ctrl.text); Navigator.pop(ctx); }, child: const Text('确定')),
        ],
      ),
    );
  }

  void _showTrailSkinPicker() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(padding: EdgeInsets.all(16), child: Text('轨迹皮肤', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            ..._trailSkins.map((skin) => RadioListTile<String>(
              title: Row(children: [Icon(skin['icon'] as IconData, size: 20), const SizedBox(width: 8), Text(skin['name'] as String)]),
              value: skin['id'] as String,
              groupValue: _settings?.trailSkin ?? 'default',
              onChanged: (v) { Navigator.pop(ctx); if (v != null) _updateSetting('trail_skin', v); },
            )),
          ],
        ),
      ),
    );
  }

  void _showNicknameColorPicker() {
    final colors = ['#EF4444', '#F59E0B', '#10B981', '#3B82F6', '#8B5CF6', '#EC4899', '#06B6D4', '#F97316'];
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(padding: EdgeInsets.all(16), child: Text('昵称颜色', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                GestureDetector(
                  onTap: () { _updateSetting('nickname_color', ''); Navigator.pop(ctx); },
                  child: Column(children: [CircleAvatar(backgroundColor: Colors.grey.shade300, child: const Icon(Icons.close, size: 18)), const SizedBox(height: 4), const Text('默认', style: TextStyle(fontSize: 11))]),
                ),
                ...colors.map((c) => GestureDetector(
                  onTap: () { _updateSetting('nickname_color', c); Navigator.pop(ctx); },
                  child: Column(children: [CircleAvatar(backgroundColor: _parseColor(c), radius: 20), const SizedBox(height: 4), Text(c, style: const TextStyle(fontSize: 10))]),
                )),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Color _parseColor(String hex) {
    try {
      hex = hex.replaceFirst('#', '');
      if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
      return Color(int.parse('FF$hex', radix: 16));
    } catch (_) {
      return const Color(0xFF4F46E5);
    }
  }

  // ==================== 4.3 紧急联系人管理 ====================

  void _showEmergencyContacts() async {
    final contacts = <Map<String, dynamic>>[];
    try {
      final list = await widget.apiService.getEmergencyContacts(widget.currentUser.id);
      contacts.addAll(list);
    } catch (_) {}

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setModalState) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('紧急联系人', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                const Text('SOS时将自动通知这些联系人', style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
                const SizedBox(height: 16),
                // 联系人列表
                ...contacts.map((c) => ListTile(
                  leading: const Icon(Icons.person, color: Color(0xFF4F46E5)),
                  title: Text(c['name'] as String? ?? ''),
                  subtitle: Text('${c['phone'] as String? ?? ''} · ${(c['relation'] as String?) ?? '家人'}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    onPressed: () async {
                      try {
                        await widget.apiService.deleteEmergencyContact(c['id'] as int);
                        setModalState(() => contacts.remove(c));
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已删除')),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('删除失败: $e')),
                          );
                        }
                      }
                    },
                  ),
                )),
                if (contacts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(child: Text('暂无紧急联系人', style: TextStyle(color: Color(0xFF94A3B8)))),
                  ),
                const SizedBox(height: 8),
                // 添加按钮
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _addEmergencyContact(contacts, setModalState),
                    icon: const Icon(Icons.add),
                    label: const Text('添加联系人'),
                  ),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  void _addEmergencyContact(List<Map<String, dynamic>> contacts, StateSetter setModalState) {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    String relation = 'family';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, dialogSetState) {
        return AlertDialog(
          title: const Text('添加紧急联系人'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '姓名', hintText: '联系人姓名')),
              const SizedBox(height: 8),
              TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: '电话', hintText: '手机号码'), keyboardType: TextInputType.phone),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: relation,
                decoration: const InputDecoration(labelText: '关系'),
                items: const [
                  DropdownMenuItem(value: 'family', child: Text('家人')),
                  DropdownMenuItem(value: 'friend', child: Text('朋友')),
                  DropdownMenuItem(value: 'colleague', child: Text('同事')),
                  DropdownMenuItem(value: 'other', child: Text('其他')),
                ],
                onChanged: (v) => dialogSetState(() => relation = v ?? 'family'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty || phoneCtrl.text.trim().isEmpty) return;
                try {
                  await widget.apiService.addEmergencyContact(
                    widget.currentUser.id, nameCtrl.text.trim(), phoneCtrl.text.trim(),
                    relation: relation,
                  );
                  final list = await widget.apiService.getEmergencyContacts(widget.currentUser.id);
                  setModalState(() {
                    contacts.clear();
                    contacts.addAll(list);
                  });
                  if (mounted) Navigator.pop(ctx);
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('添加失败: $e')),
                    );
                  }
                }
              },
              child: const Text('添加'),
            ),
          ],
        );
      }),
    );
  }

  // ==================== 4.8 GPX轨迹导出 ====================

  Future<void> _exportMyGpx() async {
    final url = widget.apiService.getGpxExportUrl(widget.currentUser.id);
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已复制GPX下载链接: $url'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }
}
