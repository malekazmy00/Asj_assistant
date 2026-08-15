import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/conversation.dart';
import '../models/file_record.dart';
import '../models/message.dart';
import '../services/supabase_service.dart';
import '../widgets/chat_composer.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _service = SupabaseService.instance;
  final _scrollController = ScrollController();

  Conversation? _conversation;
  StreamSubscription<List<ChatMessage>>? _sub;
  List<ChatMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final conversation = await _service.getOrCreateActiveConversation();
      setState(() {
        _conversation = conversation;
        _loading = false;
      });
      _sub = _service.watchMessages(conversation.id).listen((messages) {
        setState(() => _messages = messages);
        _scrollToBottom();
      });
    } catch (e) {
      setState(() {
        _error = 'Could not connect: $e';
        _loading = false;
      });
    }
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

  Future<void> _handleSend(String text) async {
    final conversation = _conversation;
    if (conversation == null) return;
    setState(() => _sending = true);
    try {
      await _service.sendMessage(conversationId: conversation.id, content: text);
    } catch (e) {
      _showError('Message failed to send: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Uploaded ${file.name}')),
        );
      }
    } catch (e) {
      _showError('Upload failed: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  LibraryFileType _fileTypeForExtension(String ext) {
    const audioExts = {'mp3', 'wav', 'm4a', 'aac'};
    const videoExts = {'mp4', 'mov', 'mkv'};
    if (audioExts.contains(ext)) return LibraryFileType.audio;
    if (videoExts.contains(ext)) return LibraryFileType.video;
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
    };
    return map[ext] ?? 'application/octet-stream';
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Medical Engineer Assistant')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildBody()),
            ChatComposer(
              sending: _sending,
              onSend: _handleSend,
              onAttach: _handleAttach,
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
    if (_messages.isEmpty) {
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
      itemCount: _messages.length,
      itemBuilder: (context, index) => MessageBubble(message: _messages[index]),
    );
  }
}
