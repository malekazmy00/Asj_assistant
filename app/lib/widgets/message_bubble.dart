import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import 'image_thumbnail.dart';
import 'rich_message_text.dart';

enum BubbleDeliveryStatus { sent, sending, failed }

class MessageBubble extends StatelessWidget {
  final String content;
  final bool isAgent;
  final List<String> attachmentFileIds;
  final BubbleDeliveryStatus status;
  final VoidCallback? onRetry;

  /// Called with the selected text when the user picks "Ask about this"
  /// from the selection toolbar. Selecting text also gets the platform's
  /// normal Copy for free via the same toolbar.
  final void Function(String selectedText)? onAskAboutSelection;

  const MessageBubble({
    super.key,
    required this.content,
    required this.isAgent,
    this.attachmentFileIds = const [],
    this.status = BubbleDeliveryStatus.sent,
    this.onRetry,
    this.onAskAboutSelection,
  });

  Widget _buildSelectableContent(TextStyle textStyle) {
    return _SelectableMessageContent(
      fullContent: content,
      onAskAboutSelection: onAskAboutSelection,
      child: RichMessageText(content: content, style: textStyle),
    );
  }

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
    final s = context.s;
    final borderColor = status == BubbleDeliveryStatus.failed
        ? Colors.red.shade300
        : (isAgent ? AppColors.agentBubbleBorder : AppColors.userBubbleBorder);

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: context.screenWidth * 0.78),
      padding: EdgeInsets.all(s(6)),
      decoration: BoxDecoration(
        color: isAgent ? AppColors.agentBubble : AppColors.userBubbleBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: kBubbleBorderWidth),
      ),
      child: Opacity(
        opacity: status == BubbleDeliveryStatus.sending ? 0.6 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (attachmentFileIds.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                  bottom: hasText ? s(6) : s(2),
                  top: s(2),
                  left: s(2),
                  right: s(2),
                ),
                child: Wrap(
                  spacing: s(6),
                  runSpacing: s(6),
                  children: attachmentFileIds
                      .map((id) => ImageThumbnail(
                            fileId: id,
                            size: s(120),
                            onTap: () => _openFullscreen(context, id),
                          ))
                      .toList(),
                ),
              ),
            if (hasText)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: s(8), vertical: s(4)),
                child: _buildSelectableContent(
                  TextStyle(color: AppColors.bubbleText, fontSize: s(15), height: 1.35),
                ),
              ),
            if (status != BubbleDeliveryStatus.sent) ...[
              SizedBox(height: s(2)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: s(8)),
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
      padding: EdgeInsets.symmetric(vertical: s(4), horizontal: s(12)),
      child: Row(
        mainAxisAlignment: isAgent ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [tappable],
      ),
    );
  }
}

/// Wraps message text in a [SelectionArea] and adds "Copy message" (the
/// whole thing, one tap, no need to select-all first) and, when a callback
/// is given, "Ask about this" for whatever's currently selected — both
/// alongside the platform's normal Copy/Select all in the same toolbar, so
/// there's one consistent long-press-to-act interaction rather than a
/// separate gesture competing with text selection. [SelectableRegionState]
/// doesn't expose the current selection directly to a context-menu
/// builder, so this widget tracks it itself via
/// [SelectionArea.onSelectionChanged].
class _SelectableMessageContent extends StatefulWidget {
  final Widget child;
  final String fullContent;
  final void Function(String selectedText)? onAskAboutSelection;

  const _SelectableMessageContent({
    required this.child,
    required this.fullContent,
    this.onAskAboutSelection,
  });

  @override
  State<_SelectableMessageContent> createState() => _SelectableMessageContentState();
}

class _SelectableMessageContentState extends State<_SelectableMessageContent> {
  String _selectedText = '';

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      onSelectionChanged: (content) => _selectedText = content?.plainText.trim() ?? '',
      contextMenuBuilder: (context, selectableRegionState) {
        final items = <ContextMenuButtonItem>[
          ...selectableRegionState.contextMenuButtonItems,
          ContextMenuButtonItem(
            label: 'Copy message',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.fullContent));
              selectableRegionState.hideToolbar();
              selectableRegionState.clearSelection();
            },
          ),
          if (widget.onAskAboutSelection != null && _selectedText.isNotEmpty)
            ContextMenuButtonItem(
              label: 'Ask about this',
              onPressed: () {
                widget.onAskAboutSelection!(_selectedText);
                selectableRegionState.hideToolbar();
                selectableRegionState.clearSelection();
              },
            ),
        ];
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: selectableRegionState.contextMenuAnchors,
          buttonItems: items,
        );
      },
      child: widget.child,
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
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.mutedText(0.45)),
          ),
          const SizedBox(width: 4),
          Text('Sending…', style: TextStyle(fontSize: 11, color: AppColors.mutedText(0.45))),
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
