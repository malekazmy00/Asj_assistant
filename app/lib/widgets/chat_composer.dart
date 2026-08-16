import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/file_record.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import 'image_thumbnail.dart';

/// Message input row: staged-image strip (if any) + text field + attach
/// button + send button.
///
/// Sending is fire-and-forget into the local outbox (see OutboxService), so
/// there's no network round trip to block on here — the field clears and
/// the message shows "sending…" immediately, even offline.
class ChatComposer extends StatefulWidget {
  final void Function(String text) onSend;
  final void Function(PlatformFile file) onAttach;
  final List<FileRecord> stagedImages;
  final void Function(int index) onRemoveStagedImage;

  const ChatComposer({
    super.key,
    required this.onSend,
    required this.onAttach,
    this.stagedImages = const [],
    required this.onRemoveStagedImage,
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
        // images
        'jpg', 'jpeg', 'png', 'webp', 'gif',
      ],
    );
    if (file != null) {
      widget.onAttach(file);
    }
  }

  void _submit() {
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
            if (widget.stagedImages.isNotEmpty) _buildStagedStrip(context),
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
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    style: TextStyle(color: AppColors.text, fontSize: s(15)),
                    decoration: const InputDecoration(hintText: 'Message'),
                    onSubmitted: (_) => _submit(),
                  ),
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

  Widget _buildStagedStrip(BuildContext context) {
    final s = context.s;
    return SizedBox(
      height: s(68),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        itemCount: widget.stagedImages.length,
        separatorBuilder: (_, _) => SizedBox(width: s(6)),
        itemBuilder: (context, index) {
          final file = widget.stagedImages[index];
          return Stack(
            clipBehavior: Clip.none,
            children: [
              ImageThumbnail(fileId: file.id, size: s(60)),
              Positioned(
                top: -6,
                right: -6,
                child: GestureDetector(
                  onTap: () => widget.onRemoveStagedImage(index),
                  child: CircleAvatar(
                    radius: 10,
                    backgroundColor: AppColors.text.withValues(alpha: 0.8),
                    child: const Icon(Icons.close, size: 13, color: AppColors.background),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
