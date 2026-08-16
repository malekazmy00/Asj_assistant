import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/file_record.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

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
      case LibraryFileType.image:
        return Icons.image;
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
      child: Text(label, style: TextStyle(fontSize: 12, color: AppColors.mutedText(0.6))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: s(16), vertical: s(12)),
      child: Row(
        children: [
          Container(
            width: s(40),
            height: s(40),
            decoration: BoxDecoration(
              color: AppColors.surface,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border, width: kBubbleBorderWidth),
            ),
            child: Icon(_icon, color: AppColors.neutralIcon, size: s(20)),
          ),
          SizedBox(width: s(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        file.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: s(15),
                          color: AppColors.text,
                        ),
                      ),
                    ),
                    if (file.tag != null) ...[
                      SizedBox(width: s(6)),
                      _TagPill(tag: file.tag!),
                    ],
                  ],
                ),
                SizedBox(height: s(2)),
                Row(
                  children: [
                    Text(
                      _sizeOrDuration,
                      style: TextStyle(fontSize: 12, color: AppColors.mutedText(0.6)),
                    ),
                    Text(
                      '  •  ${DateFormat.jm().format(file.uploadedAt)}',
                      style: TextStyle(fontSize: 12, color: AppColors.mutedText(0.6)),
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

class _TagPill extends StatelessWidget {
  final String tag;
  const _TagPill({required this.tag});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.userBubbleBackground,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        tag,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: AppColors.medicalBlue, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _VerifiedBadge extends StatelessWidget {
  final bool verified;
  const _VerifiedBadge({required this.verified});

  @override
  Widget build(BuildContext context) {
    final color = verified ? AppColors.text : AppColors.mutedText(0.4);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: verified ? AppColors.border : AppColors.mutedText(0.2)),
      ),
      child: Text(
        verified ? 'Verified' : 'Unverified',
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
