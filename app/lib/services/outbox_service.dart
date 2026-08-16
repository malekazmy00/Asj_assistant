import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/pending_message.dart';
import 'supabase_service.dart';

/// Local outbox for outgoing chat messages: offline-first send with
/// persistence, manual retry, and auto-retry on reconnect.
///
/// A message is added here the instant the user hits send — before any
/// network call — so it stays visible ("sending…" then "failed, tap to
/// retry" if needed) even if the send never reaches the server, the app is
/// backgrounded, or is killed outright. Nothing enqueued here is ever
/// silently dropped: it's removed only once the server has durably stored
/// it, persisted to disk in the meantime.
class OutboxService extends ChangeNotifier {
  OutboxService._();
  static final OutboxService instance = OutboxService._();

  static const _prefsKey = 'outbox_v1';
  static const _uuid = Uuid();

  List<PendingMessage> _items = [];
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _initialized = false;

  List<PendingMessage> forConversation(String conversationId) =>
      _items.where((m) => m.conversationId == conversationId).toList();

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as List;
        _items = decoded
            .map((e) => PendingMessage.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _items = [];
      }
    }
    notifyListeners();

    // Anything left over from a previous session (including ones that were
    // mid-flight when the app was killed) gets one immediate resend attempt
    // — safe even if it already went through, thanks to idempotent retry.
    for (final item in List<PendingMessage>.from(_items)) {
      unawaited(_attemptSend(item));
    }

    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (hasConnection) retryAllFailed();
    });
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_items.map((m) => m.toJson()).toList()));
  }

  /// Enqueues and immediately attempts to send a new message. Returns right
  /// away (fire-and-forget) — the UI reflects progress via this service's
  /// listenable state, not this future.
  void send(String conversationId, String content, {List<String> attachmentFileIds = const []}) {
    final message = PendingMessage(
      localId: _uuid.v4(),
      conversationId: conversationId,
      content: content,
      createdAt: DateTime.now().toUtc(),
      status: PendingMessageStatus.sending,
      attachmentFileIds: attachmentFileIds,
    );
    _items.add(message);
    unawaited(_persist());
    notifyListeners();
    unawaited(_attemptSend(message));
  }

  void retry(String localId) {
    final index = _items.indexWhere((m) => m.localId == localId);
    if (index == -1) return;
    _items[index] = _items[index].copyWith(status: PendingMessageStatus.sending);
    unawaited(_persist());
    notifyListeners();
    unawaited(_attemptSend(_items[index]));
  }

  void retryAllFailed() {
    for (final item in _items.where((m) => m.status == PendingMessageStatus.failed)) {
      retry(item.localId);
    }
  }

  Future<void> _attemptSend(PendingMessage message) async {
    try {
      await SupabaseService.instance.sendMessage(
        conversationId: message.conversationId,
        content: message.content,
        clientMessageId: message.localId,
        attachmentFileIds: message.attachmentFileIds,
      );
      // Success: the confirmed message will render from the realtime
      // stream (it carries this same id — see chat/index.ts), so drop the
      // local placeholder now.
      _items.removeWhere((m) => m.localId == message.localId);
      unawaited(_persist());
      notifyListeners();
    } catch (e) {
      final index = _items.indexWhere((m) => m.localId == message.localId);
      if (index == -1) return; // already resolved elsewhere
      _items[index] = _items[index].copyWith(status: PendingMessageStatus.failed);
      unawaited(_persist());
      notifyListeners();
    }
  }

  /// Defensive cleanup: drop any pending entry that has shown up in the
  /// confirmed message stream under the same id (belt-and-suspenders
  /// alongside the removal in [_attemptSend]).
  void reconcile(Iterable<String> confirmedMessageIds) {
    final before = _items.length;
    _items.removeWhere((m) => confirmedMessageIds.contains(m.localId));
    if (_items.length != before) {
      unawaited(_persist());
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }
}
