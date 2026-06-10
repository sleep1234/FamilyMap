import 'dart:async';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/socket_service.dart';

/// 圈子群聊页面
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
  }

  @override
  void dispose() {
    _msgSubscription?.cancel();
    _msgController.dispose();
    _scrollController.dispose();
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

  void _showEmojiPicker() {
    // 表情炸弹选择器
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
    widget.socketService.sendThinkingOfYou(
      userId: widget.currentUser.id,
      userName: widget.currentUser.name,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已发送"想你"通知~'), duration: Duration(seconds: 1)),
    );
  }

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
      if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
      return Color(int.parse('FF$hex', radix: 16));
    } catch (_) {
      return const Color(0xFF4F46E5);
    }
  }

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
      body: Column(
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
    );
  }

  Widget _buildMessageBubble(Message msg, bool isMe) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMe) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: _parseColor(msg.avatarColor ?? '#64748B'),
              child: Text(
                (msg.userName ?? '?')[0].toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!isMe)
                  Text(msg.userName ?? '未知', style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: isMe ? const Color(0xFF4F46E5) : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    msg.content,
                    style: TextStyle(
                      color: isMe ? Colors.white : Colors.black87,
                      fontSize: 15,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(_formatTime(msg.createdAt), style: const TextStyle(fontSize: 10, color: Color(0xFFCBD5E1))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _msgController,
                decoration: InputDecoration(
                  hintText: '说点什么...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.send, color: Color(0xFF4F46E5)),
              onPressed: _sendMessage,
            ),
          ],
        ),
      ),
    );
  }
}
