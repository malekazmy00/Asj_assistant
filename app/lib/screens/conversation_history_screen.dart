import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/conversation.dart';
import '../services/supabase_service.dart';
import '../theme/app_theme.dart';

/// Lists past conversations; tapping one pops this screen and returns its
/// id so the caller can switch to it. Past chats are never deleted or
/// overwritten by starting a new one — this is how you get back to them.
class ConversationHistoryScreen extends StatefulWidget {
  const ConversationHistoryScreen({super.key});

  @override
  State<ConversationHistoryScreen> createState() => _ConversationHistoryScreenState();
}

class _ConversationHistoryScreenState extends State<ConversationHistoryScreen> {
  final _service = SupabaseService.instance;
  List<(Conversation, String)> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final conversations = await _service.getConversations();
      final previews = await Future.wait(
        conversations.map((c) => _service.getPreview(c.id)),
      );
      setState(() {
        _items = [for (var i = 0; i < conversations.length; i++) (conversations[i], previews[i])];
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not load chats: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment_outlined, color: AppColors.facebookBlue),
            tooltip: 'New chat',
            onPressed: () => Navigator.of(context).pop('__new__'),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (_items.isEmpty) {
      return const Center(
        child: Text('No past chats yet.', style: TextStyle(color: Colors.black54)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, _) => const Divider(height: kBorderWidth, indent: 16, endIndent: 16),
        itemBuilder: (context, index) {
          final (conversation, preview) = _items[index];
          final subtitle = preview.isEmpty
              ? 'No messages yet'
              : (preview.length > 80 ? '${preview.substring(0, 80)}…' : preview);
          final timestamp = conversation.lastMessageAt ?? conversation.createdAt;
          return ListTile(
            title: Text(
              conversation.title ?? DateFormat.yMMMd().add_jm().format(timestamp),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Text(
              DateFormat.MMMd().format(timestamp),
              style: const TextStyle(fontSize: 12, color: Colors.black45),
            ),
            onTap: () => Navigator.of(context).pop(conversation.id),
          );
        },
      ),
    );
  }
}
