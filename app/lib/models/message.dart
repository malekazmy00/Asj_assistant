enum MessageRole { user, agent }

MessageRole roleFromString(String value) =>
    value == 'agent' ? MessageRole.agent : MessageRole.user;

class ChatMessage {
  final String id;
  final String conversationId;
  final MessageRole role;
  final String content;
  final String? thinkingContent;
  final DateTime createdAt;
  final Map<String, dynamic> metadata;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    this.thinkingContent,
    required this.createdAt,
    this.metadata = const {},
  });

  List<String> get attachmentFileIds {
    final raw = metadata['attachment_file_ids'];
    if (raw is! List) return const [];
    return raw.whereType<String>().toList();
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      role: roleFromString(json['role'] as String),
      content: json['content'] as String? ?? '',
      thinkingContent: json['thinking_content'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      metadata: (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }
}
