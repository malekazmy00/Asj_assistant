import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../models/file_record.dart';
import '../models/upload_task.dart';
import '../services/error_log_service.dart';
import '../services/native_bridge.dart';
import '../services/supabase_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

/// Message input row: upload-task strip (if any) + text field + attach
/// button + send button.
///
/// Sending is fire-and-forget into the local outbox (see OutboxService), so
/// there's no network round trip to block on here — the field clears and
/// the message shows "sending…" immediately, even offline.
class ChatComposer extends StatefulWidget {
  final void Function(String text) onSend;
  final void Function(PlatformFile file) onAttach;
  final List<UploadTask> uploadTasks;
  final void Function(String taskId) onRemoveUploadTask;

  /// Owned by the caller when given (e.g. ChatScreen, so "Ask about this"
  /// on a message can prefill and focus this field) — otherwise this
  /// widget manages its own, as before.
  final TextEditingController? controller;
  final FocusNode? focusNode;

  const ChatComposer({
    super.key,
    required this.onSend,
    required this.onAttach,
    this.uploadTasks = const [],
    required this.onRemoveUploadTask,
    this.controller,
    this.focusNode,
  });

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  TextEditingController? _ownedController;
  TextEditingController get _controller => widget.controller ?? (_ownedController ??= TextEditingController());

  // Voice input: tap to record a short local clip, sent to Gemini for
  // transcription (same approach as call recordings — see
  // supabase/functions/transcribe-voice-message), then dropped into the
  // text field for the user to review/edit before sending, same as if
  // they'd typed it. This replaced an on-device live-recognition
  // approach (speech_to_text) that turned out to crash unrecoverably on
  // more than one real device — see third_party/speech_to_text/PATCH_NOTES.md
  // for the full history; that path is disabled, not deleted.
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  bool _isTranscribing = false;
  String? _recordingPath;

  @override
  void dispose() {
    _recorder.dispose();
    _ownedController?.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopAndTranscribe();
      return;
    }

    // Best-effort: if the process dies right after this (native crash,
    // outside anything Dart can catch), the crash record picks this up as
    // screen_or_action — see NativeCrashReporter in MainActivity.kt.
    unawaited(NativeBridge.instance.setLastAction('tapped mic button (record)'));

    try {
      if (!await _recorder.hasPermission()) {
        _showVoiceError("Couldn't start recording — check the microphone permission for this app.");
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      _recordingPath = path;
      if (mounted) setState(() => _isRecording = true);
    } catch (e, stack) {
      unawaited(ErrorLogService.instance.logError(
        level: 'error',
        source: 'dart',
        errorType: e.runtimeType.toString(),
        message: e.toString(),
        stackTrace: stack.toString(),
        screenOrAction: 'starting voice recording',
      ));
      _showVoiceError('Voice input error: $e');
    }
  }

  Future<void> _stopAndTranscribe() async {
    final path = await _recorder.stop();
    if (mounted) setState(() => _isRecording = false);
    final usablePath = path ?? _recordingPath;
    _recordingPath = null;
    if (usablePath == null) return;

    final file = File(usablePath);
    setState(() => _isTranscribing = true);
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        _showVoiceError("Didn't catch anything — try again.");
        return;
      }
      final transcript = await SupabaseService.instance.transcribeVoiceMessage(
        bytes: bytes,
        mimeType: 'audio/mp4', // AudioEncoder.aacLc's container (.m4a is an MP4 variant)
      );
      final existing = _controller.text;
      final joined = existing.trim().isEmpty ? transcript : '$existing $transcript';
      _controller.text = joined;
      _controller.selection = TextSelection.collapsed(offset: joined.length);
    } catch (e, stack) {
      unawaited(ErrorLogService.instance.logError(
        level: 'error',
        source: 'dart',
        errorType: e.runtimeType.toString(),
        message: e.toString(),
        stackTrace: stack.toString(),
        screenOrAction: 'transcribing voice message',
      ));
      _showVoiceError('Voice input error: $e');
    } finally {
      if (mounted) setState(() => _isTranscribing = false);
      // Local temp clip, never uploaded anywhere as a file — clean it up.
      unawaited(() async {
        try {
          await file.delete();
        } catch (_) {}
      }());
    }
  }

  void _showVoiceError(String message) {
    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isTranscribing = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickAttachment() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const [
        // documents
        'pdf', 'doc', 'docx', 'txt', 'md',
        // audio
        'mp3', 'wav', 'm4a', 'aac',
        // video
        'mp4', 'mov', 'mkv',
        // images
        'jpg', 'jpeg', 'png', 'webp', 'gif',
      ],
    );
    if (file != null) {
      widget.onAttach(file);
    }
  }

  void _submit() {
    if (_isRecording) {
      _recorder.cancel();
      setState(() => _isRecording = false);
    }
    final text = _controller.text.trim();
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(top: BorderSide(color: AppColors.divider, width: kBorderWidth)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.uploadTasks.isNotEmpty) _buildUploadStrip(context),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: Icon(Icons.attach_file, color: AppColors.neutralIcon, size: s(24)),
                  onPressed: _pickAttachment,
                  tooltip: 'Attach file',
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: widget.focusNode,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    style: TextStyle(color: AppColors.text, fontSize: s(15)),
                    decoration: InputDecoration(
                      hintText: _isRecording
                          ? 'Recording… tap mic to stop'
                          : _isTranscribing
                              ? 'Transcribing…'
                              : 'Message',
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                _isTranscribing
                    ? Padding(
                        padding: EdgeInsets.symmetric(horizontal: s(12)),
                        child: SizedBox(
                          width: s(20),
                          height: s(20),
                          child: const CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: Icon(
                          _isRecording ? Icons.stop_circle : Icons.mic_none,
                          color: _isRecording ? Colors.red.shade400 : AppColors.neutralIcon,
                          size: s(24),
                        ),
                        onPressed: _toggleRecording,
                        tooltip: _isRecording ? 'Stop recording' : 'Voice input',
                      ),
                SizedBox(width: s(4)),
                IconButton(
                  icon: Icon(Icons.send, color: AppColors.medicalBlue, size: s(24)),
                  onPressed: _submit,
                  tooltip: 'Send',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUploadStrip(BuildContext context) {
    final s = context.s;
    return SizedBox(
      height: s(68),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        itemCount: widget.uploadTasks.length,
        separatorBuilder: (_, _) => SizedBox(width: s(6)),
        itemBuilder: (context, index) {
          final task = widget.uploadTasks[index];
          return _UploadTaskChip(
            task: task,
            size: s(60),
            onRemove: () => widget.onRemoveUploadTask(task.id),
          );
        },
      ),
    );
  }
}

class _UploadTaskChip extends StatelessWidget {
  final UploadTask task;
  final double size;
  final VoidCallback onRemove;

  const _UploadTaskChip({required this.task, required this.size, required this.onRemove});

  IconData get _icon {
    switch (task.fileType) {
      case LibraryFileType.audio:
        return Icons.audiotrack;
      case LibraryFileType.video:
        return Icons.videocam;
      case LibraryFileType.document:
        return Icons.description;
      case LibraryFileType.image:
        return Icons.image;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: task.status == UploadTaskStatus.failed
          ? () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('Couldn\'t upload "${task.filename}"'),
                  content: Text(task.errorMessage ?? 'Unknown error'),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
                  ],
                ),
              )
          : null,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: task.status == UploadTaskStatus.failed ? Colors.red.shade300 : AppColors.border,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (task.previewBytes != null)
                  Image.memory(task.previewBytes!, fit: BoxFit.cover)
                else
                  Center(child: Icon(_icon, color: AppColors.neutralIcon, size: size * 0.4)),
                if (task.status == UploadTaskStatus.uploading || task.status == UploadTaskStatus.processing)
                  Container(
                    color: Colors.black.withValues(alpha: 0.45),
                    child: Center(
                      child: task.status == UploadTaskStatus.processing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : Text(
                              '${(task.progress * 100).round()}%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                if (task.status == UploadTaskStatus.failed)
                  Container(
                    color: Colors.red.withValues(alpha: 0.5),
                    child: const Center(
                      child: Icon(Icons.error_outline, color: Colors.white, size: 22),
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: onRemove,
              child: CircleAvatar(
                radius: 10,
                backgroundColor: AppColors.text.withValues(alpha: 0.8),
                child: const Icon(Icons.close, size: 13, color: AppColors.background),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
