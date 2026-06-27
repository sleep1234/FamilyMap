import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/api_service.dart';
import 'avatar_widget.dart';

/// 头像选择器弹窗
/// 支持：生肖卡通头像、Emoji预设头像、从相册选择照片、拍照、移除头像
class AvatarPicker extends StatefulWidget {
  final String userId;
  final String currentName;
  final String currentAvatarColor;
  final String? currentAvatarUrl;
  final ApiService apiService;

  const AvatarPicker({
    super.key,
    required this.userId,
    required this.currentName,
    this.currentAvatarColor = '#4F46E5',
    this.currentAvatarUrl,
    required this.apiService,
  });

  @override
  State<AvatarPicker> createState() => _AvatarPickerState();
}

class _AvatarPickerState extends State<AvatarPicker> {
  bool _isUploading = false;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题
              Row(
                children: [
                  const Text('选择头像', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  _buildCurrentAvatar(32),
                ],
              ),
              const SizedBox(height: 20),

              // === 生肖头像区 ===
              _sectionLabel('十二生肖'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: ZodiacPresetData.all.map((z) {
                  final isSelected = widget.currentAvatarUrl == z.storageKey;
                  return GestureDetector(
                    onTap: () => _selectZodiac(z),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: isSelected
                                ? Border.all(color: const Color(0xFF4F46E5), width: 3)
                                : Border.all(color: Colors.grey.shade200, width: 1),
                          ),
                          child: ZodiacAvatarWidget(zodiac: z, size: 56),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          z.name,
                          style: TextStyle(
                            fontSize: 10,
                            color: isSelected ? const Color(0xFF4F46E5) : const Color(0xFF94A3B8),
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),

              const SizedBox(height: 16),

              // === Emoji 预设区 ===
              _sectionLabel('趣味头像'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: PresetAvatarData.all.map((preset) {
                  final isSelected = widget.currentAvatarUrl == preset.storageKey;
                  return GestureDetector(
                    onTap: () => _selectPreset(preset),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        border: isSelected
                            ? Border.all(color: const Color(0xFF4F46E5), width: 3)
                            : null,
                      ),
                      child: PresetAvatarWidget(preset: preset, size: 48),
                    ),
                  );
                }).toList(),
              ),

              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 12),

              // 从相册选择 / 拍照
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isUploading ? null : _pickFromGallery,
                      icon: const Icon(Icons.photo_library, size: 20),
                      label: const Text('从相册选择'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isUploading ? null : _pickFromCamera,
                      icon: const Icon(Icons.camera_alt, size: 20),
                      label: const Text('拍照'),
                    ),
                  ),
                ],
              ),

              // 移除头像
              if (widget.currentAvatarUrl != null && widget.currentAvatarUrl!.isNotEmpty) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: _isUploading ? null : _removeAvatar,
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                    label: const Text('移除头像', style: TextStyle(color: Colors.redAccent)),
                  ),
                ),
              ],

              // 上传进度
              if (_isUploading) ...[
                const SizedBox(height: 12),
                const Center(child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 8),
                    Text('上传中...', style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                  ],
                )),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Row(
      children: [
        Text(text, style: const TextStyle(fontSize: 13, color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
        const SizedBox(width: 6),
        const Expanded(child: Divider(height: 1)),
      ],
    );
  }

  Widget _buildCurrentAvatar(double s) {
    return AvatarWidget(
      name: widget.currentName,
      avatarColor: widget.currentAvatarColor,
      avatarUrl: widget.currentAvatarUrl,
      size: s,
    );
  }

  Future<void> _selectZodiac(ZodiacPresetData zodiac) async {
    try {
      await widget.apiService.updateUser(widget.userId, {
        'avatar_url': zodiac.storageKey,
      });
      if (mounted) Navigator.pop(context, zodiac.storageKey);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('设置失败: $e')));
      }
    }
  }

  Future<void> _selectPreset(PresetAvatarData preset) async {
    try {
      await widget.apiService.updateUser(widget.userId, {
        'avatar_url': preset.storageKey,
      });
      if (mounted) Navigator.pop(context, preset.storageKey);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('设置失败: $e')));
      }
    }
  }

  Future<void> _pickFromGallery() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(
      source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 80,
    );
    if (image == null) return;
    await _uploadImage(image.path);
  }

  Future<void> _pickFromCamera() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(
      source: ImageSource.camera, maxWidth: 512, maxHeight: 512, imageQuality: 80,
    );
    if (image == null) return;
    await _uploadImage(image.path);
  }

  Future<void> _uploadImage(String filePath) async {
    setState(() => _isUploading = true);
    try {
      final avatarUrl = await widget.apiService.uploadAvatar(widget.userId, filePath);
      if (mounted) Navigator.pop(context, avatarUrl);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('上传失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _removeAvatar() async {
    try {
      await widget.apiService.deleteAvatar(widget.userId);
      if (mounted) Navigator.pop(context, '');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('移除失败: $e')));
      }
    }
  }
}

/// 显示头像选择器
Future<String?> showAvatarPicker({
  required BuildContext context,
  required String userId,
  required String currentName,
  String currentAvatarColor = '#4F46E5',
  String? currentAvatarUrl,
  required ApiService apiService,
}) async {
  final result = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => AvatarPicker(
      userId: userId,
      currentName: currentName,
      currentAvatarColor: currentAvatarColor,
      currentAvatarUrl: currentAvatarUrl,
      apiService: apiService,
    ),
  );
  return result;
}
