import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/conversation.dart';
import '../models/file_record.dart';
import '../models/message.dart';
import '../models/pending_message.dart';
import '../services/image_cache_service.dart';
import '../services/outbox_service.dart';
import '../services/session_service.dart';
import '../services/supabase_service.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_composer.dart';
import '../widgets/message_bubble.dart';
import 'conversation_history_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// A single row to render: either a confirmed message from the server or a
/// still-local pending one. Deduplicated by id — see _mergedRows.
class _ChatRow {
  final ChatMessage? confirmed;
  final PendingMessage? pending;
  _ChatRow.confirmed(ChatMessage m)
      : confirmed = m,
        pending = null;
  _ChatRow.pending(PendingMessage m)
      : confirmed = null,
        pending = m;

  DateTime get createdAt => confirmed?.createdAt ?? pending!.createdAt;
}

class _ChatScreenState extends State<ChatScreen> {
  final _service = SupabaseService.instance;
  final _outbox = OutboxService.instance;
  final _scrollController = ScrollController();

  Conversation? _conversation;
  StreamSubscription<List<ChatMessage>>? _sub;
  List<ChatMessage> _messages = [];
  List<FileRecord> _stagedImages = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _outbox.addListener(_onOutboxChanged);
    _init();
  }

  Future<void> _init() async {
    try {
      final conversation = await _resolveStartupConversation();
      await _switchTo(conversation, persist: false);
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _error = 'Could not connect: $e';
        _loading = false;
      });
    }
  }

  Future<Conversation> _resolveStartupConversation() async {
    final savedId = await SessionService.instance.getCurrentConversationId();
    if (savedId != null) {
      final existing = await _service.getConversation(savedId);
      if (existing != null) return existing;
    }
    return _service.getOrCreateActiveConversation();
  }

  Future<void> _switchTo(Conversation conversation, {bool persist = true}) async {
    await _sub?.cancel();
    setState(() {
      _conversation = conversation;
      _messages = [];
    });
    if (persist) {
      await SessionService.instance.setCurrentConversationId(conversation.id);
    }
    _sub = _service.watchMessages(conversation.id).listen((messages) {
      _outbox.reconcile(messages.map((m) => m.id));
      setState(() => _messages = messages);
      _scrollToBottom();
    });
  }

  void _onOutboxChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  List<_ChatRow> get _mergedRows {
    final confirmedIds = _messages.map((m) => m.id).toSet();
    final rows = [
      ..._messages.map(_ChatRow.confirmed),
      ..._outbox
          .forConversation(_conversation?.id ?? '')
          .where((p) => !confirmedIds.contains(p.localId))
          .map(_ChatRow.pending),
    ];
    rows.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return rows;
  }

  void _handleSend(String text) {
    final conversation = _conversation;
    if (conversation == null) return;
    if (text.trim().isEmpty && _stagedImages.isEmpty) return;
    final attachmentIds = _stagedImages.map((f) => f.id).toList();
    _outbox.send(conversation.id, text, attachmentFileIds: attachmentIds);
    setState(() => _stagedImages = []);
    _scrollToBottom();
  }

  Future<void> _handleNewChat() async {
    final conversation = await _service.createConversation();
    await _switchTo(conversation);
  }

  Future<void> _handleOpenHistory() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ConversationHistoryScreen()),
    );
    if (result == null) return;
    if (result == '__new__') {
      await _handleNewChat();
      return;
    }
    if (result == _conversation?.id) return;
    final selected = await _service.getConversation(result);
    if (selected != null) await _switchTo(selected);
  }

  Future<void> _handleAttach(PlatformFile file) async {
    final conversation = _conversation;
    if (conversation == null) return;

    final nameParts = file.name.split('.');
    final ext = nameParts.length > 1 ? nameParts.last.toLowerCase() : '';
    final fileType = _fileTypeForExtension(ext);
    final mimeType = _mimeTypeForExtension(ext);

    try {
      final bytes = await file.readAsBytes();
      final record = await _service.uploadFile(
        conversationId: conversation.id,
        filename: file.name,
        bytes: bytes,
        mimeType: mimeType,
        fileType: fileType,
      );
      await _service.triggerFileProcessing(record.id);

      if (fileType == LibraryFileType.image) {
        // Images aren't a standalone "upload and process" thing like docs —
        // they're staged and go out attached to the next message, straight
        // to Claude's vision input.
        ImageCacheService.instance.primeBytes(record.id, bytes);
        if (mounted) setState(() => _stagedImages = [..._stagedImages, record]);
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Uploaded ${file.name}')),
        );
      }
    } catch (e) {
      _showError('Upload failed: $e');
    }
  }

  void _handleRemoveStagedImage(int index) {
    setState(() {
      _stagedImages = [..._stagedImages]..removeAt(index);
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  LibraryFileType _fileTypeForExtension(String ext) {
    const audioExts = {'mp3', 'wav', 'm4a', 'aac'};
    const videoExts = {'mp4', 'mov', 'mkv'};
    const imageExts = {'jpg', 'jpeg', 'png', 'webp', 'gif'};
    if (audioExts.contains(ext)) return LibraryFileType.audio;
    if (videoExts.contains(ext)) return LibraryFileType.video;
    if (imageExts.contains(ext)) return LibraryFileType.image;
    return LibraryFileType.document;
  }

  String _mimeTypeForExtension(String ext) {
    const map = {
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'txt': 'text/plain',
      'md': 'text/markdown',
      'mp3': 'audio/mpeg',
      'wav': 'audio/wav',
      'm4a': 'audio/mp4',
      'aac': 'audio/aac',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'mkv': 'video/x-matroska',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
      'gif': 'image/gif',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  @override
  void dispose() {
    _outbox.removeListener(_onOutboxChanged);
    _sub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Medical Engineer Assistant'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history, color: AppColors.facebookBlue),
            tooltip: 'Past chats',
            onPressed: _handleOpenHistory,
          ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined, color: AppColors.facebookBlue),
            tooltip: 'New chat',
            onPressed: _handleNewChat,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildBody()),
            ChatComposer(
              onSend: _handleSend,
              onAttach: _handleAttach,
              stagedImages: _stagedImages,
              onRemoveStagedImage: _handleRemoveStagedImage,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    final rows = _mergedRows;
    if (rows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Say hello to get started.',
            style: TextStyle(color: Colors.black54),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        if (row.confirmed != null) {
          return MessageBubble(
            content: row.confirmed!.content,
            isAgent: row.confirmed!.role == MessageRole.agent,
            attachmentFileIds: row.confirmed!.attachmentFileIds,
          );
        }
        final pending = row.pending!;
        return MessageBubble(
          content: pending.content,
          isAgent: false,
          attachmentFileIds: pending.attachmentFileIds,
          status: pending.status == PendingMessageStatus.sending
              ? BubbleDeliveryStatus.sending
              : BubbleDeliveryStatus.failed,
          onRetry: () => _outbox.retry(pending.localId),
        );
      },
    );
  }
}
