import 'package:flutter/material.dart';
import '../config.dart';
import '../services/image_cache_service.dart';

// 默认圆角比例：size * 0.27 ≒ 44→12, 40→11, 32→9
double _defaultBorderRadius(double size) => (size * 0.27).roundToDouble();

/// 通用头像 Widget —— 全局统一方形圆角风格
/// 支持：自定义图片URL > 生肖预设(图片) > Emoji预设 > 颜色+首字母
class AvatarWidget extends StatelessWidget {
  final String name;
  final String avatarColor;
  final String? avatarUrl;
  final double size;
  final double borderRadius;

  const AvatarWidget({
    super.key,
    required this.name,
    this.avatarColor = '#4F46E5',
    this.avatarUrl,
    this.size = 44,
    this.borderRadius = 0, // 0 时自动按 size*0.27
  });

  double get _br => borderRadius > 0 ? borderRadius : _defaultBorderRadius(size);

  @override
  Widget build(BuildContext context) {
    final url = avatarUrl;

    // 1. 生肖图片型预设 (preset:zodiac_xxx)
    final zodiac = ZodiacPresetData.findByKey(url);
    if (zodiac != null) {
      return _networkAvatar('${AppConfig.httpBaseUrl}${zodiac.imageUrl}', bgColor: zodiac.bgColor);
    }

    // 2. Emoji 型预设 (preset:cat 等)
    final emoji = PresetAvatarData.findByKey(url);
    if (emoji != null) {
      return _emojiAvatar(emoji);
    }

    // 3. 自定义上传图片URL
    if (url != null && url.isNotEmpty) {
      final fullUrl = url.startsWith('http') ? url : '${AppConfig.httpBaseUrl}$url';
      return _networkAvatar(fullUrl);
    }

    // 4. 无头像 → 颜色+首字母
    return _letterAvatar();
  }

  // ---- 网络图片方形圆角（带本地缓存） ----
  Widget _networkAvatar(String imageUrl, {Color? bgColor}) {
    return CachedAvatarImage(
      url: imageUrl,
      size: size,
      borderRadius: _br,
      bgColor: bgColor ?? _parseColor(avatarColor),
    );
  }

  // ---- Emoji 方形圆角 ----
  Widget _emojiAvatar(PresetAvatarData emoji) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_br),
        color: emoji.bgColor,
      ),
      child: Center(child: Text(emoji.emoji, style: TextStyle(fontSize: size * 0.5), textScaleFactor: 1.0)),
    );
  }

  // ---- 首字母方形圆角 ----
  Widget _letterAvatar() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_br),
        color: _parseColor(avatarColor),
      ),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.41,
            fontWeight: FontWeight.w800,
          ),
          textScaleFactor: 1.0,
        ),
      ),
    );
  }

  Color _parseColor(String hex) {
    try {
      hex = hex.replaceFirst('#', '');
      if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join('');
      return Color(int.parse('FF$hex', radix: 16));
    } catch (_) {
      return const Color(0xFF4F46E5);
    }
  }
}

// ==================== Emoji 型预设头像 ====================

class PresetAvatarData {
  final String id;
  final String emoji;
  final String label;
  final Color bgColor;

  const PresetAvatarData({
    required this.id,
    required this.emoji,
    required this.label,
    required this.bgColor,
  });

  /// 服务器存储格式：preset:id
  String get storageKey => 'preset:$id';

  static const List<PresetAvatarData> all = [
    PresetAvatarData(id: 'cat', emoji: '🐱', label: '猫咪', bgColor: Color(0xFFF97316)),
    PresetAvatarData(id: 'dog', emoji: '🐶', label: '小狗', bgColor: Color(0xFF8B5CF6)),
    PresetAvatarData(id: 'bear', emoji: '🐻', label: '小熊', bgColor: Color(0xFF64748B)),
    PresetAvatarData(id: 'fox', emoji: '🦊', label: '狐狸', bgColor: Color(0xFFEF4444)),
    PresetAvatarData(id: 'panda', emoji: '🐼', label: '熊猫', bgColor: Color(0xFF1E293B)),
    PresetAvatarData(id: 'rabbit', emoji: '🐰', label: '兔子', bgColor: Color(0xFFEC4899)),
    PresetAvatarData(id: 'star', emoji: '⭐', label: '星星', bgColor: Color(0xFFF59E0B)),
    PresetAvatarData(id: 'moon', emoji: '🌙', label: '月亮', bgColor: Color(0xFF1E40AF)),
    PresetAvatarData(id: 'sun', emoji: '☀️', label: '太阳', bgColor: Color(0xFFDC2626)),
    PresetAvatarData(id: 'flower', emoji: '🌸', label: '花朵', bgColor: Color(0xFFDB2777)),
    PresetAvatarData(id: 'car', emoji: '🚗', label: '汽车', bgColor: Color(0xFF059669)),
    PresetAvatarData(id: 'bike', emoji: '🚲', label: '自行车', bgColor: Color(0xFF0891B2)),
    PresetAvatarData(id: 'rocket', emoji: '🚀', label: '火箭', bgColor: Color(0xFF4F46E5)),
    PresetAvatarData(id: 'tree', emoji: '🌳', label: '大树', bgColor: Color(0xFF16A34A)),
    PresetAvatarData(id: 'wave', emoji: '🌊', label: '海浪', bgColor: Color(0xFF2563EB)),
    PresetAvatarData(id: 'rainbow', emoji: '🌈', label: '彩虹', bgColor: Color(0xFF7C3AED)),
  ];

  static PresetAvatarData? findByKey(String? key) {
    if (key == null || !key.startsWith('preset:')) return null;
    final id = key.substring(7);
    try {
      return all.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }
}

// ==================== 生肖图片型预设头像 ====================

class ZodiacPresetData {
  final String id;         // zodiac_rat
  final String name;       // 子鼠
  final String label;      // 鼠
  final Color bgColor;
  final String imageUrl;   // /uploads/presets/zodiac_rat.jpg

  const ZodiacPresetData({
    required this.id,
    required this.name,
    required this.label,
    required this.bgColor,
    required this.imageUrl,
  });

  /// 服务器存储格式：preset:zodiac_rat
  String get storageKey => 'preset:$id';

  static const List<ZodiacPresetData> all = [
    ZodiacPresetData(id: 'zodiac_rat',     name: '子鼠', label: '鼠', bgColor: Color(0xFFFDE8E8), imageUrl: '/uploads/presets/zodiac_rat.jpg'),
    ZodiacPresetData(id: 'zodiac_ox',      name: '丑牛', label: '牛', bgColor: Color(0xFFE8F0FE), imageUrl: '/uploads/presets/zodiac_ox.jpg'),
    ZodiacPresetData(id: 'zodiac_tiger',   name: '寅虎', label: '虎', bgColor: Color(0xFFFEE8D0), imageUrl: '/uploads/presets/zodiac_tiger.jpg'),
    ZodiacPresetData(id: 'zodiac_rabbit',  name: '卯兔', label: '兔', bgColor: Color(0xFFF3E8FD), imageUrl: '/uploads/presets/zodiac_rabbit.jpg'),
    ZodiacPresetData(id: 'zodiac_dragon',  name: '辰龙', label: '龙', bgColor: Color(0xFFFDF6D0), imageUrl: '/uploads/presets/zodiac_dragon.jpg'),
    ZodiacPresetData(id: 'zodiac_snake',   name: '巳蛇', label: '蛇', bgColor: Color(0xFFD8F5E0), imageUrl: '/uploads/presets/zodiac_snake.jpg'),
    ZodiacPresetData(id: 'zodiac_horse',   name: '午马', label: '马', bgColor: Color(0xFFF0E4D8), imageUrl: '/uploads/presets/zodiac_horse.jpg'),
    ZodiacPresetData(id: 'zodiac_goat',    name: '未羊', label: '羊', bgColor: Color(0xFFF5F0E0), imageUrl: '/uploads/presets/zodiac_goat.jpg'),
    ZodiacPresetData(id: 'zodiac_monkey',  name: '申猴', label: '猴', bgColor: Color(0xFFFDF6D0), imageUrl: '/uploads/presets/zodiac_monkey.jpg'),
    ZodiacPresetData(id: 'zodiac_rooster', name: '酉鸡', label: '鸡', bgColor: Color(0xFFFDE8E8), imageUrl: '/uploads/presets/zodiac_rooster.jpg'),
    ZodiacPresetData(id: 'zodiac_dog',     name: '戌狗', label: '狗', bgColor: Color(0xFFF0E4D8), imageUrl: '/uploads/presets/zodiac_dog.jpg'),
    ZodiacPresetData(id: 'zodiac_pig',     name: '亥猪', label: '猪', bgColor: Color(0xFFFDE8F0), imageUrl: '/uploads/presets/zodiac_pig.jpg'),
  ];

  static ZodiacPresetData? findByKey(String? key) {
    if (key == null || !key.startsWith('preset:zodiac_')) return null;
    final id = key.substring(7); // preset:zodiac_rat → zodiac_rat
    try {
      return all.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }
}

/// 生肖预设头像 Widget（方形圆角 + 可选地支名标签）—— 用于选择器
class ZodiacAvatarWidget extends StatelessWidget {
  final ZodiacPresetData zodiac;
  final double size;
  final bool showLabel;

  const ZodiacAvatarWidget({
    super.key,
    required this.zodiac,
    this.size = 56,
    this.showLabel = false,
  });

  @override
  Widget build(BuildContext context) {
    final br = _defaultBorderRadius(size);
    final avatar = CachedAvatarImage(
      url: '${AppConfig.httpBaseUrl}${zodiac.imageUrl}',
      size: size,
      borderRadius: br,
      bgColor: zodiac.bgColor,
    );

    if (!showLabel) return avatar;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        avatar,
        const SizedBox(height: 2),
        Text(
          zodiac.name,
          style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
        ),
      ],
    );
  }
}

/// Emoji 预设头像 Widget（方形圆角）—— 用于选择器
class PresetAvatarWidget extends StatelessWidget {
  final PresetAvatarData preset;
  final double size;

  const PresetAvatarWidget({
    super.key,
    required this.preset,
    this.size = 48,
  });

  @override
  Widget build(BuildContext context) {
    final br = _defaultBorderRadius(size);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(br),
        color: preset.bgColor,
      ),
      child: Center(child: Text(preset.emoji, style: TextStyle(fontSize: size * 0.5))),
    );
  }
}
