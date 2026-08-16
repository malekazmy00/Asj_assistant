import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/image_cache_service.dart';
import '../theme/app_theme.dart';

/// Renders an image attachment by file id — from the in-memory cache
/// instantly if it was just uploaded in this session, otherwise fetched
/// from Storage and cached from then on.
class ImageThumbnail extends StatefulWidget {
  final String fileId;
  final double size;
  final VoidCallback? onTap;

  const ImageThumbnail({super.key, required this.fileId, this.size = 160, this.onTap});

  @override
  State<ImageThumbnail> createState() => _ImageThumbnailState();
}

class _ImageThumbnailState extends State<ImageThumbnail> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = ImageCacheService.instance.getBytes(widget.fileId);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: FutureBuilder<Uint8List?>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _placeholder(loading: true);
          }
          final bytes = snapshot.data;
          if (bytes == null) return _placeholder(loading: false);
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              bytes,
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
            ),
          );
        },
      ),
    );
  }

  Widget _placeholder({required bool loading}) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: AppColors.userBubbleBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.facebookBlue.withValues(alpha: 0.3)),
      ),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.broken_image_outlined, color: Colors.black26),
      ),
    );
  }
}
