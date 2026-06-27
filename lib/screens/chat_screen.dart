import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../config.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/socket_service.dart';
import '../widgets/avatar_widget.dart';

/// 圈子群聊页面（支持文字 + 语音消息）
class ChatScreen extends StatefulWidget {
  final Circle circle;
  final AppUser currentUser;
  final SocketService socketService;
  final ApiService apiService;

  const ChatScreen({
    super.key,
    required this.circle,
    required this.currentUser,
    required this.socketService,
    required this.apiService,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  List<Message> _messages = [];
  StreamSubscription<Message>? _msgSubscription;
  bool _isLoading = true;

  // 录音
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  bool _isCancelBySwipe = false; // 上滑取消标记
  bool _isVoiceMode = false; // 语音模式：输入框变为按住按钮
  DateTime? _recordStartTime;
  String? _recordPath;
  Timer? _recordingTimer; // 录音计时器（每秒刷新显示）
  int _recordingSeconds = 0;
  // 录音手势的起始Y坐标，用于判断上滑取消
  double _recordStartY = 0;

  // 播放
  final AudioPlayer _player = AudioPlayer();
  int? _playingMsgId;
  StreamSubscription? _playerStateSub;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _msgSubscription = widget.socketService.onChatMessage.listen((msg) {
      if (msg.circleId == widget.circle.id) {
        setState(() => _messages.add(msg));
        _scrollToBottom();
      }
    });
    _playerStateSub = _player.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.completed || state == PlayerState.stopped) {
        setState(() => _playingMsgId = null);
      }
    });
  }

  @override
  void dispose() {
    _msgSubscription?.cancel();
    _playerStateSub?.cancel();
    _msgController.dispose();
    _scrollController.dispose();
    _recordingTimer?.cancel();
    // 修复：先 stop recorder 再 dispose，避免页面关闭时正在录音导致崩溃
    if (_isRecording) {
      _recorder.stop().then((_) {
        _recorder.dispose();
        // 清理临时文件
        if (_recordPath != null) {
          try { File(_recordPath!).delete(); } catch (_) {}
        }
      });
    } else {
      _recorder.dispose();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    try {
      final msgs = await widget.apiService.getMessages(widget.circle.id);
      setState(() {
        _messages = msgs;
        _isLoading = false;
      });
      _scrollToBottom();
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ==================== 文字消息 ====================

  Future<void> _sendMessage() async {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;
    _msgController.clear();

    try {
      await widget.apiService.sendMessage(
        widget.circle.id, widget.currentUser.id, text,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送失败: $e')),
        );
      }
    }
  }

  // ==================== 语音消息 ====================

  Future<void> _startRecording() async {
    // 检查录音权限
    final hasPermission = await _recorder.hasPermission();
    if (hasPermission != true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('需要麦克风权限才能录音'), duration: Duration(seconds: 2)),
        );
      }
      return;
    }

    try {
      final dir = await getTemporaryDirectory();
      _recordPath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1, sampleRate: 44100),
        path: _recordPath!,
      );
      setState(() {
        _isRecording = true;
        _recordStartTime = DateTime.now();
        _recordingSeconds = 0;
      });
      // 开始录音震动反馈，增加交互感
      HapticFeedback.mediumImpact();
      // 每秒刷新录音计时
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordingSeconds++);
      });
    } catch (e) {
      debugPrint('[录音] 启动录音失败: $e');
    }
  }

  Future<void> _stopAndSendRecording() async {
    if (!_isRecording) return;

    // 松手发送震动反馈
    HapticFeedback.lightImpact();

    try {
      final path = await _recorder.stop();
      _recordingTimer?.cancel();
      setState(() {
        _isRecording = false;
        _isCancelBySwipe = false;
      });

      if (path == null || _recordStartTime == null) return;

      final duration = DateTime.now().difference(_recordStartTime!).inSeconds;
      if (duration < 1) {
        // 太短，取消发送（微信风格：显示"说话时间太短"）
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('说话时间太短'), duration: Duration(seconds: 1)),
          );
        }
        return;
      }

      // 上传音频
      final result = await widget.apiService.uploadAudio(path, duration: duration);
      final audioUrl = result['url'] as String;

      // 发送音频消息：type=audio, content="url|duration"
      await widget.apiService.sendMessage(
        widget.circle.id,
        widget.currentUser.id,
        '$audioUrl|$duration',
        type: 'audio',
      );

      // 上传成功后删除本地临时文件
      if (_recordPath != null) {
        try { File(_recordPath!).delete(); } catch (_) {}
      }
      _recordingTimer?.cancel();
    } catch (e) {
      setState(() {
        _isRecording = false;
        _isCancelBySwipe = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('语音发送失败: $e')),
        );
      }
    }
  }

  Future<void> _cancelRecording() async {
    if (!_isRecording) return;
    // 取消录音震动反馈
    HapticFeedback.heavyImpact();
    await _recorder.stop();
    _recordingTimer?.cancel();
    setState(() {
      _isRecording = false;
      _isCancelBySwipe = false;
    });
    // 删除临时文件
    if (_recordPath != null) {
      try { File(_recordPath!).delete(); } catch (_) {}
    }
  }

  Future<void> _playVoice(Message msg) async {
    if (msg.type != 'audio' || msg.content.isEmpty) return;

    final parts = msg.content.split('|');
    final urlPart = parts[0];
    final fullUrl = urlPart.startsWith('http') ? urlPart : '${AppConfig.httpBaseUrl}$urlPart';

    // 停止当前播放
    if (_playingMsgId != null) {
      await _player.stop();
      setState(() => _playingMsgId = null);
    }

    setState(() => _playingMsgId = msg.id);
    try {
      await _player.play(UrlSource(fullUrl));
    } catch (e) {
      debugPrint('[播放] 语音播放失败: $e');
      setState(() => _playingMsgId = null);
    }
  }

  // ==================== 互动功能 ====================

  void _showEmojiPicker() {
    final emojis = ['❤️', '😂', '🥺', '🔥', '👍', '🎉', '💕', '😎', '🤗', '✨'];
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('表情轰炸', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: emojis.map((e) => GestureDetector(
                onTap: () {
                  widget.socketService.sendEmojiBomb(
                    userId: widget.currentUser.id, emoji: e,
                  );
                  Navigator.pop(ctx);
                },
                child: Text(e, style: const TextStyle(fontSize: 32)),
              )).toList(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _sendThinkingOfYou() {
    // 群聊中"想你"广播给圈子所有成员（不传 targetUserId）
    widget.socketService.sendThinkingOfYou(
      userId: widget.currentUser.id,
      userName: widget.currentUser.name,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已发送"想你"通知~'), duration: Duration(seconds: 1)),
    );
  }

  // ==================== 格式化 ====================

  String _formatTime(DateTime? t) {
    if (t == null) return '';
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
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

  /// 解析语音消息时长
  int _parseVoiceDuration(String content) {
    final parts = content.split('|');
    if (parts.length >= 2) return int.tryParse(parts[1]) ?? 0;
    return 0;
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.circle.name),
        actions: [
          IconButton(icon: const Icon(Icons.favorite_border), onPressed: _sendThinkingOfYou, tooltip: '想你'),
          IconButton(icon: const Icon(Icons.emoji_emotions_outlined), onPressed: _showEmojiPicker, tooltip: '表情轰炸'),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // 消息列表
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _messages.isEmpty
                        ? const Center(child: Text('还没有消息，开始聊天吧', style: TextStyle(color: Color(0xFF94A3B8))))
                        : ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            itemCount: _messages.length,
                            itemBuilder: (ctx, i) {
                              final msg = _messages[i];
                              final isMe = msg.userId == widget.currentUser.id;
                              return _buildMessageBubble(msg, isMe);
                            },
                          ),
              ),
              // 输入栏
              _buildInputBar(),
            ],
          ),
          // 录音中浮层提示，居中显示
          if (_isRecording) _buildRecordingOverlay(),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(Message msg, bool isMe) {
    final isVoice = msg.type == 'audio';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMe) ...[
            _buildChatAvatar(msg),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                // 所有消息都显示发送人名称
                Text(
                  isMe ? '我' : (msg.userName ?? '未知'),
                  style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                ),
                const SizedBox(height: 2),
                isVoice ? _buildVoiceBubble(msg, isMe) : _buildTextBubble(msg, isMe),
                const SizedBox(height: 2),
                Text(_formatTime(msg.createdAt), style: const TextStyle(fontSize: 10, color: Color(0xFFCBD5E1))),
              ],
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: 8),
            _buildSelfAvatar(),
          ],
        ],
      ),
    );
  }

  Widget _buildTextBubble(Message msg, bool isMe) {
    final bgColor = isMe ? const Color(0xFF4F46E5) : (_isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9));
    final textColor = isMe ? Colors.white : (_isDark ? Colors.white70 : Colors.black87);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        msg.content,
        style: TextStyle(color: textColor, fontSize: 15),
      ),
    );
  }

  Widget _buildVoiceBubble(Message msg, bool isMe) {
    final duration = _parseVoiceDuration(msg.content);
    final isPlaying = _playingMsgId == msg.id;
    // 语音气泡宽度根据时长调整，最小80dp，最大200dp
    final width = (80.0 + duration * 4).clamp(80.0, 200.0);
    final bgColor = isMe ? const Color(0xFF4F46E5) : (_isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9));
    final iconColor = isMe ? Colors.white : const Color(0xFF4F46E5);
    final waveColor = isMe ? Colors.white60 : const Color(0xFF4F46E5).withOpacity(0.5);
    final durColor = isMe ? Colors.white70 : (_isDark ? Colors.white60 : const Color(0xFF64748B));

    return GestureDetector(
      onTap: () => _playVoice(msg),
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 播放/暂停图标
            Icon(
              isPlaying ? Icons.pause_circle : (isMe ? Icons.play_circle_fill : Icons.play_circle_outline),
              color: iconColor,
              size: 24,
            ),
            const SizedBox(width: 6),
            // 声波动画
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: List.generate(
                  3,
                  (i) => Container(
                    width: 2,
                    height: [8, 14, 6][i].toDouble(),
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    decoration: BoxDecoration(
                      color: waveColor,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ),
            ),
            // 时长
            Text(
              '${duration}s',
              style: TextStyle(
                color: durColor,
                fontSize: 12,
              ),
              textScaleFactor: 1.0,
            ),
          ],
        ),
      ),
    );
  }

  /// 是否处于暗黑模式（基于 app 主题，而非系统亮度）
  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  Widget _buildInputBar() {
    final bgColor = _isDark ? const Color(0xFF1E293B) : Colors.white;
    final borderColor = _isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: SafeArea(
        top: false,
        // 录音中：底部按钮变为"按住 说话"（微信风格），同时叠加中央浮层提示
        child: _buildNormalInputBar(),
      ),
    );
  }

  Widget _buildNormalInputBar() {
    final hintColor = _isDark ? const Color(0xFF64748B) : null;
    final fillColor = _isDark ? const Color(0xFF0F172A) : null;
    final iconBgColor = _isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9);
    final iconColor = _isDark ? const Color(0xFF818CF8) : const Color(0xFF4F46E5);
    return Row(
      children: [
        // 左侧图标：语音模式显示键盘，文字模式显示麦克风
        GestureDetector(
          onTap: () => setState(() => _isVoiceMode = !_isVoiceMode),
          child: Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: iconBgColor,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              _isVoiceMode ? Icons.keyboard : Icons.mic,
              color: iconColor,
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 中间区域：语音模式=按住按钮，文字模式=输入框
        Expanded(
          child: _isVoiceMode ? _buildVoiceButton() : _buildTextInput(hintColor, fillColor),
        ),
        const SizedBox(width: 8),
        // 文字模式：发送按钮
        if (!_isVoiceMode)
          IconButton(
            icon: Icon(Icons.send, color: iconColor),
            onPressed: _sendMessage,
          ),
      ],
    );
  }

  /// 语音模式下的"按住 说话"长条按钮
  Widget _buildVoiceButton() {
    final bgColor = _isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9);
    final activeBgColor = _isCancelBySwipe
        ? const Color(0xFFEF4444)
        : (_isRecording ? const Color(0xFF4F46E5) : bgColor);
    final textColor = _isDark ? Colors.white : Colors.black87;
    return GestureDetector(
      onLongPressStart: (details) {
        _recordStartY = details.globalPosition.dy;
        _startRecording();
      },
      onLongPressMoveUpdate: (details) {
        // 上滑超过 80px → 标记为取消
        final dy = details.globalPosition.dy - _recordStartY;
        final shouldCancel = dy < -80;
        if (shouldCancel != _isCancelBySwipe) {
          setState(() => _isCancelBySwipe = shouldCancel);
          HapticFeedback.lightImpact();
        }
      },
      onLongPressEnd: (details) {
        if (_isCancelBySwipe) {
          _cancelRecording();
        } else {
          _stopAndSendRecording();
        }
      },
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: activeBgColor,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          _isRecording
              ? (_isCancelBySwipe ? '松开手指，取消发送' : '手指上滑，取消发送')
              : '按住 说话',
          style: TextStyle(color: _isRecording ? Colors.white : textColor, fontSize: 15),
          textScaleFactor: 1.0,
        ),
      ),
    );
  }

  /// 文字模式下的输入框
  Widget _buildTextInput(Color? hintColor, Color? fillColor) {
    return TextField(
      controller: _msgController,
      decoration: InputDecoration(
        hintText: '说点什么...',
        hintStyle: hintColor != null ? TextStyle(color: hintColor) : null,
        filled: fillColor != null,
        fillColor: fillColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: _isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: _isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: Color(0xFF4F46E5)),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => _sendMessage(),
    );
  }

  /// 录音中浮层提示，居中屏幕（微信风格）
  Widget _buildRecordingOverlay() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isCancelBySwipe ? Icons.cancel : Icons.mic,
              color: _isCancelBySwipe ? const Color(0xFFEF4444) : Colors.white,
              size: 48,
            ),
            const SizedBox(height: 8),
            Text(
              _isCancelBySwipe
                  ? '松开手指，取消发送'
                  : '手指上滑，取消发送',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            if (!_isCancelBySwipe)
              Text(
                '${_recordingSeconds}s',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 聊天中的头像
  Widget _buildChatAvatar(Message msg) {
    return AvatarWidget(
      name: msg.userName ?? '?',
      avatarColor: msg.avatarColor ?? '#64748B',
      avatarUrl: msg.avatarUrl,
      size: 32,
    );
  }

  /// 自己的头像
  Widget _buildSelfAvatar() {
    return AvatarWidget(
      name: widget.currentUser.name,
      avatarColor: widget.currentUser.avatarColor ?? '#4F46E5',
      avatarUrl: widget.currentUser.avatarUrl,
      size: 32,
    );
  }
}
