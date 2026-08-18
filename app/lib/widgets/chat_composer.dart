import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../models/file_record.dart';
import '../models/upload_task.dart';
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

  // Voice input: on-device speech-to-text as a typing alternative — no
  // audio ever leaves the device, no cloud round trip, no dedicated chat.
  // Distinct from uploading a call recording (attach button): single
  // utterance, transcribed locally, just lands in the text field like
  // typing would. The recognized text is cumulative per listening
  // session, so it replaces (rather than appends to) whatever was already
  // typed before this session started — _textBeforeListening is what it's
  // laid back on top of.
  final SpeechToText _speech = SpeechToText();
  bool _speechInitialized = false;
  bool _isListening = false;
  String _textBeforeListening = '';

  @override
  void dispose() {
    _speech.stop();
    _ownedController?.dispose();
    super.dispose();
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speech.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }

    try {
      if (!_speechInitialized) {
        _speechInitialized = await _speech.initialize(
          onError: (e) => _showSpeechError('Voice input error: ${e.errorMsg}'),
          onStatus: (status) {
            if ((status == 'notListening' || status == 'done') && mounted) {
              setState(() => _isListening = false);
            }
          },
          // This app has no use for Bluetooth-headset mic input, and asking
          // for it costs a second runtime permission (BLUETOOTH_CONNECT)
          // that this app's manifest doesn't declare — requesting an
          // undeclared dangerous permission is a real Android crash class
          // on a number of OS/OEM combinations, which is exactly what was
          // happening here. Opting out is the plugin's own documented fix
          // for apps that don't need Bluetooth support.
          options: [SpeechToText.androidNoBluetooth],
        );
      }
      if (!_speechInitialized) {
        _showSpeechError("Couldn't start voice input — check the microphone permission for this app.");
        return;
      }

      _textBeforeListening = _controller.text;
      setState(() => _isListening = true);
      await _speech.listen(
        onResult: (result) {
          final joined = _textBeforeListening.isEmpty
              ? result.recognizedWords
              : '$_textBeforeListening ${result.recognizedWords}';
          _controller.text = joined;
          _controller.selection = TextSelection.collapsed(offset: joined.length);
        },
      );
    } catch (e) {
      // Defense in depth: any PlatformException from the plugin (native
      // errors are supposed to come back this way, not as a crash) lands
      // here as a graceful message instead of an uncaught exception out of
      // a button handler.
      _showSpeechError('Voice input error: $e');
    }
  }

  void _showSpeechError(String message) {
    if (!mounted) return;
    setState(() => _isListening = false);
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
    if (_isListening) {
      _speech.stop();
      setState(() => _isListening = false);
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
                      hintText: _isListening ? 'Listening…' : 'Message',
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _isListening ? Icons.mic : Icons.mic_none,
                    color: _isListening ? AppColors.medicalBlue : AppColors.neutralIcon,
                    size: s(24),
                  ),
                  onPressed: _toggleListening,
                  tooltip: _isListening ? 'Stop voice input' : 'Voice input',
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
