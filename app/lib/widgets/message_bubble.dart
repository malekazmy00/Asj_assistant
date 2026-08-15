import 'package:flutter/material.dart';

import '../models/message.dart';
import '../theme/app_theme.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isAgent = message.role == MessageRole.agent;

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isAgent ? AppColors.agentBubble : AppColors.userBubbleBackground,
        borderRadius: BorderRadius.circular(16),
        border: isAgent
            ? null
            : Border.all(color: AppColors.userBubbleBorder, width: kBorderWidth),
      ),
      child: Text(
        message.content,
        style: const TextStyle(color: AppColors.bubbleText, fontSize: 15, height: 1.35),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      child: Row(
        mainAxisAlignment: isAgent ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [bubble],
      ),
    );
  }
}
