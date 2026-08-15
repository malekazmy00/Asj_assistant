class Conversation {
  final String id;
  final String? title;
  final DateTime createdAt;
  final DateTime? lastMessageAt;

  Conversation({
    required this.id,
    this.title,
    required this.createdAt,
    this.lastMessageAt,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'] as String,
      title: json['title'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      lastMessageAt: json['last_message_at'] != null
          ? DateTime.parse(json['last_message_at'] as String)
          : null,
    );
  }
}
