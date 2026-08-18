import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../models/conversation.dart';
import '../models/file_record.dart';
import '../models/message.dart';
import '../models/pending_message.dart';
import '../models/upload_task.dart';
import '../services/export_service.dart';
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
  List<UploadTask> _uploadTasks = [];
  bool _loading = true;
  String? _error;

  final _composerController = TextEditingController();
  final _composerFocusNode = FocusNode();

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
    final readyImages = _uploadTasks.where(
      (t) => t.fileType == LibraryFileType.image && t.status == UploadTaskStatus.completed,
    );
    final attachmentIds = readyImages.map((t) => t.fileId!).toList();
    if (text.trim().isEmpty && attachmentIds.isEmpty) return;
    _outbox.send(conversation.id, text, attachmentFileIds: attachmentIds);
    final sentIds = readyImages.map((t) => t.id).toSet();
    setState(() => _uploadTasks = _uploadTasks.where((t) => !sentIds.contains(t.id)).toList());
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
    if (_conversation == null) return;

    final nameParts = file.name.split('.');
    final ext = nameParts.length > 1 ? nameParts.last.toLowerCase() : '';
    final fileType = _fileTypeForExtension(ext);
    final mimeType = _mimeTypeForExtension(ext);

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      _showError('Could not read ${file.name}: $e');
      return;
    }

    // Call recordings get their own dedicated chat rather than joining
    // whatever's currently open — lets the agent focus fully on that one
    // recording (asking about unclear parts, etc.) without competing with
    // unrelated topics. Everything else (documents, images) still goes
    // into the current conversation as before.
    Conversation targetConversation;
    final isRecording = fileType == LibraryFileType.audio || fileType == LibraryFileType.video;
    if (isRecording) {
      targetConversation = await _service.createConversation();
      await _service.updateConversationTitle(targetConversation.id, _titleForRecording(file.name));
      await _switchTo(targetConversation);
    } else {
      targetConversation = _conversation!;
    }

    // Documents get an optional light tag (brand/device type) at upload
    // time — used for Library filtering and to help the agent weight
    // related sources. Not asked for other file types; keep it quick.
    String? tag;
    if (fileType == LibraryFileType.document) {
      tag = await _promptForTag();
    }

    final taskId = const Uuid().v4();
    final task = UploadTask(
      id: taskId,
      filename: file.name,
      fileType: fileType,
      previewBytes: fileType == LibraryFileType.image ? bytes : null,
    );
    setState(() => _uploadTasks = [..._uploadTasks, task]);

    void updateTask(UploadTask Function(UploadTask current) update) {
      if (!mounted) return;
      setState(() {
        _uploadTasks = _uploadTasks.map((t) => t.id == taskId ? update(t) : t).toList();
      });
    }

    try {
      final record = await _service.uploadFileWithProgress(
        conversationId: targetConversation.id,
        filename: file.name,
        bytes: bytes,
        mimeType: mimeType,
        fileType: fileType,
        tag: tag,
        onProgress: (progress) => updateTask((t) => t.copyWith(progress: progress)),
      );
      if (isRecording) {
        await _service.setConversationSeedFile(targetConversation.id, record.id);
      }
      unawaited(_service.triggerFileProcessing(record.id));

      if (fileType == LibraryFileType.image) {
        // Images aren't a standalone "upload and process" thing like docs —
        // they stay staged in the composer and go out attached to the next
        // message, straight to Claude's vision input.
        ImageCacheService.instance.primeBytes(record.id, bytes);
        updateTask((t) => t.copyWith(status: UploadTaskStatus.completed, fileId: record.id));
        return;
      }

      updateTask((t) => t.copyWith(status: UploadTaskStatus.processing, fileId: record.id));
      // Non-image uploads aren't attached to a message — they've been
      // handed off to the server (chunking+embedding, or queued for
      // transcription) — so the chip's job is done; clear it shortly.
      Future.delayed(const Duration(seconds: 2), () {
        if (!mounted) return;
        setState(() => _uploadTasks = _uploadTasks.where((t) => t.id != taskId).toList());
      });
    } catch (e) {
      updateTask((t) => t.copyWith(status: UploadTaskStatus.failed, errorMessage: _cleanError(e)));
    }
  }

  /// A first-pass title for a call recording's new dedicated chat — cleaned
  /// up from the filename when that's actually informative, falling back
  /// to the upload date otherwise (e.g. auto-named "REC0231.m4a" phone
  /// recordings, or "audio_2026...".wav" style names). Always renamable
  /// afterward via the existing rename feature.
  String _titleForRecording(String filename) {
    final base = filename.contains('.') ? filename.substring(0, filename.lastIndexOf('.')) : filename;
    final cleaned = base.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
    final looksMeaningful = cleaned.isNotEmpty && RegExp(r'[a-zA-Z؀-ۿ]{3,}').hasMatch(cleaned);
    if (looksMeaningful) return cleaned;
    return 'Call recording — ${DateFormat.yMMMd().format(DateTime.now())}';
  }

  Future<String?> _promptForTag() async {
    final controller = TextEditingController();
    final tag = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tag this document? (optional)'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Siemens, GE, X-ray'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Skip')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Add tag'),
          ),
        ],
      ),
    );
    if (tag == null || tag.trim().isEmpty) return null;
    return tag.trim();
  }

  String _cleanError(Object e) => e.toString().replaceFirst('Exception: ', '');

  void _handleRemoveUploadTask(String taskId) {
    setState(() => _uploadTasks = _uploadTasks.where((t) => t.id != taskId).toList());
  }

  void _handleAskAboutSelection(String selectedText) {
    final quoted = selectedText.split('\n').map((l) => '> $l').join('\n');
    _composerController.text = '$quoted\n';
    _composerController.selection = TextSelection.collapsed(offset: _composerController.text.length);
    _composerFocusNode.requestFocus();
  }

  Future<void> _handleRename() async {
    final conversation = _conversation;
    if (conversation == null) return;
    final controller = TextEditingController(text: conversation.title ?? '');
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Chat name'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newTitle == null || newTitle.trim().isEmpty) return;
    try {
      await _service.updateConversationTitle(conversation.id, newTitle.trim());
      if (mounted) {
        setState(() {
          _conversation = Conversation(
            id: conversation.id,
            title: newTitle.trim(),
            createdAt: conversation.createdAt,
            lastMessageAt: conversation.lastMessageAt,
          );
        });
      }
    } catch (e) {
      _showError('Could not rename chat: $e');
    }
  }

  Future<void> _handleExport() async {
    final conversation = _conversation;
    if (conversation == null) return;
    try {
      await ExportService.instance.exportConversation(conversation, _messages);
    } catch (e) {
      _showError('Could not export chat: $e');
    }
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
    _composerController.dispose();
    _composerFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_conversation?.title ?? 'Medical Engineer Assistant'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history, color: AppColors.neutralIcon),
            tooltip: 'Past chats',
            onPressed: _handleOpenHistory,
          ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined, color: AppColors.neutralIcon),
            tooltip: 'New chat',
            onPressed: _handleNewChat,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: AppColors.neutralIcon),
            onSelected: (value) {
              if (value == 'rename') _handleRename();
              if (value == 'export') _handleExport();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename chat')),
              PopupMenuItem(value: 'export', child: Text('Export chat')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildBody()),
            ChatComposer(
              controller: _composerController,
              focusNode: _composerFocusNode,
              onSend: _handleSend,
              onAttach: _handleAttach,
              uploadTasks: _uploadTasks,
              onRemoveUploadTask: _handleRemoveUploadTask,
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Say hello to get started.',
            style: TextStyle(color: AppColors.mutedText(0.55)),
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
            onAskAboutSelection: _handleAskAboutSelection,
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
