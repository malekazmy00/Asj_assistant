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
  // Captured at send time (from the composer's search toggle — see
  // SearchPreferenceService) rather than read fresh on every retry, so a
  // retry always resends with the same search setting the user actually
  // saw when they hit send, not whatever the toggle happens to be later.
  final bool enableSearch;

  PendingMessage({
    required this.localId,
    required this.conversationId,
    required this.content,
    required this.createdAt,
    required this.status,
    this.attachmentFileIds = const [],
    this.enableSearch = true,
  });

  PendingMessage copyWith({PendingMessageStatus? status}) {
    return PendingMessage(
      localId: localId,
      conversationId: conversationId,
      content: content,
      createdAt: createdAt,
      status: status ?? this.status,
      attachmentFileIds: attachmentFileIds,
      enableSearch: enableSearch,
    );
  }

  Map<String, dynamic> toJson() => {
        'localId': localId,
        'conversationId': conversationId,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
        'status': status.name,
        'attachmentFileIds': attachmentFileIds,
        'enableSearch': enableSearch,
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
      // Missing on an older queued message (from before this field
      // existed) — default true, matching the app's prior always-on behavior.
      enableSearch: json['enableSearch'] as bool? ?? true,
    );
  }
}
