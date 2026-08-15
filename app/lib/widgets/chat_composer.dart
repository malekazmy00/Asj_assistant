import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Message input row: text field + attach button + send button.
///
/// Sending is fire-and-forget into the local outbox (see OutboxService), so
/// there's no network round trip to block on here — the field clears and
/// the message shows "sending…" immediately, even offline.
class ChatComposer extends StatefulWidget {
  final void Function(String text) onSend;
  final void Function(PlatformFile file) onAttach;

  const ChatComposer({
    super.key,
    required this.onSend,
    required this.onAttach,
  });

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final _controller = TextEditingController();

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
      ],
    );
    if (file != null) {
      widget.onAttach(file);
    }
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(top: BorderSide(color: AppColors.divider, width: kBorderWidth)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: const Icon(Icons.attach_file, color: AppColors.facebookBlue),
              onPressed: _pickAttachment,
              tooltip: 'Attach file',
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'Message'),
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.send, color: AppColors.facebookBlue),
              onPressed: _submit,
              tooltip: 'Send',
            ),
          ],
        ),
      ),
    );
  }
}
