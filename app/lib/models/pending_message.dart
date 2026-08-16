enum PendingMessageStatus { sending, failed }

/// A locally-queued outgoing message: created the instant the user hits
/// send, before any network call, so it can survive a dropped connection
/// or a killed app without ever silently disappearing. `localId` doubles
/// as the eventual server-side message id (see SupabaseService.sendMessage
/// / chat/index.ts) — the same id is resent on every retry, which is what
/// makes retries idempotent instead of creating duplicates.
class PendingMessage {
  final String localId;
  final String conversationId;
  final String content;
  final DateTime createdAt;
  final PendingMessageStatus status;
  final List<String> attachmentFileIds;

  PendingMessage({
    required this.localId,
    required this.conversationId,
    required this.content,
    required this.createdAt,
    required this.status,
    this.attachmentFileIds = const [],
  });

  PendingMessage copyWith({PendingMessageStatus? status}) {
    return PendingMessage(
      localId: localId,
      conversationId: conversationId,
      content: content,
      createdAt: createdAt,
      status: status ?? this.status,
      attachmentFileIds: attachmentFileIds,
    );
  }

  Map<String, dynamic> toJson() => {
        'localId': localId,
        'conversationId': conversationId,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
        'status': status.name,
        'attachmentFileIds': attachmentFileIds,
      };

  factory PendingMessage.fromJson(Map<String, dynamic> json) {
    return PendingMessage(
      localId: json['localId'] as String,
      conversationId: json['conversationId'] as String,
      content: json['content'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      status: PendingMessageStatus.values.byName(json['status'] as String? ?? 'failed'),
      attachmentFileIds:
          (json['attachmentFileIds'] as List?)?.whereType<String>().toList() ?? const [],
    );
  }
}
