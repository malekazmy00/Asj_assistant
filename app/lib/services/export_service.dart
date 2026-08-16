import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/conversation.dart';
import '../models/message.dart';

/// Exports a full conversation as a plain-text file and hands it to the
/// platform share sheet — the standard, permission-free way to get a file
/// out of a Flutter app on Android (save to Drive, send via WhatsApp/email,
/// etc., whatever the user picks).
class ExportService {
  ExportService._();
  static final ExportService instance = ExportService._();

  Future<void> exportConversation(Conversation conversation, List<ChatMessage> messages) async {
    final buffer = StringBuffer();
    final title = conversation.title ?? 'Medical Engineer Assistant chat';
    buffer.writeln(title);
    buffer.writeln(DateFormat.yMMMMd().add_jm().format(conversation.createdAt));
    buffer.writeln('=' * 40);
    buffer.writeln();

    for (final message in messages) {
      final who = message.role == MessageRole.agent ? 'Medical Engineer Assistant' : 'You';
      final when = DateFormat.yMMMd().add_jm().format(message.createdAt);
      buffer.writeln('$who — $when');
      buffer.writeln(message.content.trim().isEmpty ? '[attachment]' : message.content.trim());
      buffer.writeln();
    }

    final dir = await getTemporaryDirectory();
    final safeName = title.replaceAll(RegExp(r'[^\w\-]+'), '_').toLowerCase();
    final file = File('${dir.path}/${safeName}_${DateTime.now().millisecondsSinceEpoch}.txt');
    await file.writeAsString(buffer.toString());

    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], subject: title),
    );
  }
}
