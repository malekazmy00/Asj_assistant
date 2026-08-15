enum LibraryFileType { document, audio, video }

LibraryFileType fileTypeFromString(String value) {
  switch (value) {
    case 'audio':
      return LibraryFileType.audio;
    case 'video':
      return LibraryFileType.video;
    default:
      return LibraryFileType.document;
  }
}

enum ProcessingStatus { pending, processing, completed, failed }

ProcessingStatus processingStatusFromString(String value) {
  switch (value) {
    case 'processing':
      return ProcessingStatus.processing;
    case 'completed':
      return ProcessingStatus.completed;
    case 'failed':
      return ProcessingStatus.failed;
    default:
      return ProcessingStatus.pending;
  }
}

class FileRecord {
  final String id;
  final LibraryFileType fileType;
  final String filename;
  final String storagePath;
  final String? mimeType;
  final int? sizeBytes;
  final double? durationSeconds;
  final ProcessingStatus processingStatus;
  final DateTime uploadedAt;
  // Admin-only visual (this is the single-user app, so it's fine to show for
  // now) — never surfaced anywhere in the chat UI itself.
  final bool verified;

  FileRecord({
    required this.id,
    required this.fileType,
    required this.filename,
    required this.storagePath,
    this.mimeType,
    this.sizeBytes,
    this.durationSeconds,
    required this.processingStatus,
    required this.uploadedAt,
    this.verified = false,
  });

  factory FileRecord.fromJson(Map<String, dynamic> json) {
    return FileRecord(
      id: json['id'] as String,
      fileType: fileTypeFromString(json['file_type'] as String),
      filename: json['filename'] as String,
      storagePath: json['storage_path'] as String,
      mimeType: json['mime_type'] as String?,
      sizeBytes: json['size_bytes'] as int?,
      durationSeconds: (json['duration_seconds'] as num?)?.toDouble(),
      processingStatus: processingStatusFromString(json['processing_status'] as String),
      uploadedAt: DateTime.parse(json['uploaded_at'] as String),
      verified: (json['verification_status'] as String? ?? 'unverified') == 'verified',
    );
  }
}
