import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/file_record.dart';
import '../theme/app_theme.dart';

class LibraryRow extends StatelessWidget {
  final FileRecord file;

  const LibraryRow({super.key, required this.file});

  IconData get _icon {
    switch (file.fileType) {
      case LibraryFileType.audio:
        return Icons.audiotrack;
      case LibraryFileType.video:
        return Icons.videocam;
      case LibraryFileType.document:
        return Icons.description;
    }
  }

  String get _sizeOrDuration {
    if (file.durationSeconds != null) {
      final d = Duration(seconds: file.durationSeconds!.round());
      final minutes = d.inMinutes;
      final seconds = d.inSeconds % 60;
      return '$minutes:${seconds.toString().padLeft(2, '0')}';
    }
    final bytes = file.sizeBytes;
    if (bytes == null) return '';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _statusChip() {
    final status = file.processingStatus;
    if (status == ProcessingStatus.completed) return const SizedBox.shrink();
    final label = switch (status) {
      ProcessingStatus.pending => 'Queued',
      ProcessingStatus.processing => 'Processing…',
      ProcessingStatus.failed => 'Failed',
      ProcessingStatus.completed => '',
    };
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.userBubbleBackground,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.facebookBlue, width: kBorderWidth),
            ),
            child: Icon(_icon, color: AppColors.facebookBlue, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      _sizeOrDuration,
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    Text(
                      '  •  ${DateFormat.jm().format(file.uploadedAt)}',
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    _statusChip(),
                  ],
                ),
              ],
            ),
          ),
          _VerifiedBadge(verified: file.verified),
        ],
      ),
    );
  }
}

class _VerifiedBadge extends StatelessWidget {
  final bool verified;
  const _VerifiedBadge({required this.verified});

  @override
  Widget build(BuildContext context) {
    final color = verified ? AppColors.facebookBlue : Colors.black38;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: kBorderWidth),
      ),
      child: Text(
        verified ? 'Verified' : 'Unverified',
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
