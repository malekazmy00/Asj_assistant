import 'dart:typed_data';

import 'supabase_service.dart';

/// In-memory (session-only, not persisted) byte cache for image
/// attachments. A freshly-picked image is "primed" with its bytes the
/// moment it's uploaded, so its own bubble renders instantly with no
/// round trip; older/historical attachments are fetched from Storage on
/// first render and cached from then on.
class ImageCacheService {
  ImageCacheService._();
  static final ImageCacheService instance = ImageCacheService._();

  final Map<String, Uint8List> _bytes = {};
  final Map<String, Future<Uint8List?>> _inFlight = {};

  void primeBytes(String fileId, Uint8List bytes) {
    _bytes[fileId] = bytes;
  }

  Future<Uint8List?> getBytes(String fileId) {
    final cached = _bytes[fileId];
    if (cached != null) return Future.value(cached);

    return _inFlight.putIfAbsent(fileId, () async {
      try {
        final bytes = await SupabaseService.instance.downloadFileBytesById(fileId);
        if (bytes != null) _bytes[fileId] = bytes;
        return bytes;
      } finally {
        _inFlight.remove(fileId);
      }
    });
  }
}
