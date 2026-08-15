import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../models/conversation.dart';
import '../models/file_record.dart';
import '../models/message.dart';

/// Thin wrapper around the Supabase client. The Flutter app talks to
/// Supabase directly (anon key + permissive v1 RLS) for reading/writing
/// conversations, messages, and file metadata, and invokes the `chat` Edge
/// Function for anything that needs the Anthropic key or server-side logic.
class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  SupabaseClient get _client => Supabase.instance.client;

  static Future<void> initialize() async {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
    );
  }

  // ---------------------------------------------------------------------
  // Conversations
  // ---------------------------------------------------------------------

  Future<Conversation> getOrCreateActiveConversation() async {
    final existing = await _client
        .from('conversations')
        .select()
        .order('last_message_at', ascending: false, nullsFirst: false)
        .limit(1);

    if (existing.isNotEmpty) {
      return Conversation.fromJson(existing.first);
    }

    final created = await _client.from('conversations').insert({}).select().single();
    return Conversation.fromJson(created);
  }

  // ---------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------

  Future<List<ChatMessage>> getMessages(String conversationId) async {
    final rows = await _client
        .from('messages')
        .select()
        .eq('conversation_id', conversationId)
        .order('created_at');
    return rows.map((row) => ChatMessage.fromJson(row)).toList();
  }

  Stream<List<ChatMessage>> watchMessages(String conversationId) {
    return _client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at')
        .map((rows) => rows.map((row) => ChatMessage.fromJson(row)).toList());
  }

  /// Sends a user message and gets the agent's reply, via the `chat` Edge
  /// Function (it owns persistence of both sides, including the agent's
  /// extended-thinking content, and does all knowledge extraction silently).
  Future<ChatMessage> sendMessage({
    required String conversationId,
    required String content,
    List<String> attachmentFileIds = const [],
  }) async {
    final response = await _client.functions.invoke(
      'chat',
      body: {
        'conversation_id': conversationId,
        'content': content,
        'attachment_file_ids': attachmentFileIds,
      },
    );

    if (response.status != 200) {
      throw Exception('chat function failed: ${response.status} ${response.data}');
    }

    final data = response.data as Map<String, dynamic>;
    return ChatMessage.fromJson(data['message'] as Map<String, dynamic>);
  }

  // ---------------------------------------------------------------------
  // Files / Library
  // ---------------------------------------------------------------------

  Future<List<FileRecord>> getFiles({LibraryFileType? filterType}) async {
    var query = _client.from('files').select();
    if (filterType != null) {
      query = query.eq('file_type', filterType.name);
    }
    final rows = await query.order('uploaded_at', ascending: false);
    return rows.map((row) => FileRecord.fromJson(row)).toList();
  }

  Future<FileRecord> uploadFile({
    required String conversationId,
    required String filename,
    required Uint8List bytes,
    required String mimeType,
    required LibraryFileType fileType,
  }) async {
    final storagePath =
        '${fileType.name}/${DateTime.now().millisecondsSinceEpoch}_$filename';

    await _client.storage.from('uploads').uploadBinary(
          storagePath,
          bytes,
          fileOptions: FileOptions(contentType: mimeType, upsert: false),
        );

    final row = await _client
        .from('files')
        .insert({
          'conversation_id': conversationId,
          'file_type': fileType.name,
          'filename': filename,
          'storage_path': storagePath,
          'mime_type': mimeType,
          'size_bytes': bytes.length,
          'processing_status': fileType == LibraryFileType.document ? 'pending' : 'pending',
        })
        .select()
        .single();

    return FileRecord.fromJson(row);
  }

  /// Kicks off server-side processing for a freshly uploaded file
  /// (document chunking+embedding, or queuing for the WhisperX worker).
  Future<void> triggerFileProcessing(String fileId) async {
    await _client.functions.invoke('process-file', body: {'file_id': fileId});
  }
}
