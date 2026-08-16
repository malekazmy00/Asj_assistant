import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'image_thumbnail.dart';

enum BubbleDeliveryStatus { sent, sending, failed }

class MessageBubble extends StatelessWidget {
  final String content;
  final bool isAgent;
  final List<String> attachmentFileIds;
  final BubbleDeliveryStatus status;
  final VoidCallback? onRetry;

  const MessageBubble({
    super.key,
    required this.content,
    required this.isAgent,
    this.attachmentFileIds = const [],
    this.status = BubbleDeliveryStatus.sent,
    this.onRetry,
  });

  void _openFullscreen(BuildContext context, String fileId) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(
            child: InteractiveViewer(
              child: ImageThumbnail(fileId: fileId, size: double.infinity),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasText = content.trim().isNotEmpty;

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: isAgent ? AppColors.agentBubble : AppColors.userBubbleBackground,
        borderRadius: BorderRadius.circular(16),
        border: isAgent
            ? null
            : Border.all(
                color: status == BubbleDeliveryStatus.failed
                    ? Colors.red.shade400
                    : AppColors.userBubbleBorder,
                width: kBorderWidth,
              ),
      ),
      child: Opacity(
        opacity: status == BubbleDeliveryStatus.sending ? 0.6 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (attachmentFileIds.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: hasText ? 6 : 2, top: 2, left: 2, right: 2),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: attachmentFileIds
                      .map((id) => ImageThumbnail(
                            fileId: id,
                            size: 120,
                            onTap: () => _openFullscreen(context, id),
                          ))
                      .toList(),
                ),
              ),
            if (hasText)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  content,
                  style: const TextStyle(color: AppColors.bubbleText, fontSize: 15, height: 1.35),
                ),
              ),
            if (status != BubbleDeliveryStatus.sent) ...[
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _StatusRow(status: status, onRetry: onRetry),
              ),
            ],
          ],
        ),
      ),
    );

    final tappable = status == BubbleDeliveryStatus.failed && onRetry != null
        ? GestureDetector(onTap: onRetry, child: bubble)
        : bubble;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      child: Row(
        mainAxisAlignment: isAgent ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [tappable],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final BubbleDeliveryStatus status;
  final VoidCallback? onRetry;

  const _StatusRow({required this.status, this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (status == BubbleDeliveryStatus.sending) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.black45),
          ),
          SizedBox(width: 4),
          Text('Sending…', style: TextStyle(fontSize: 11, color: Colors.black45)),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline, size: 12, color: Colors.red.shade400),
        const SizedBox(width: 4),
        Text(
          'Not sent — tap to retry',
          style: TextStyle(fontSize: 11, color: Colors.red.shade400, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
