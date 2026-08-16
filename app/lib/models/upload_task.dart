import 'dart:typed_data';

import 'file_record.dart';

enum UploadTaskStatus { uploading, processing, completed, failed }

/// Local, UI-only representation of an attachment as it moves through
/// picking -> uploading -> (for documents) processing -> done. Exists so
/// the composer can show an immediate preview and real upload progress
/// instead of the attach button just going quiet until a SnackBar shows up
/// afterwards.
class UploadTask {
  final String id;
  final String filename;
  final LibraryFileType fileType;
  final Uint8List? previewBytes; // images only — local bytes, no round trip
  final double progress; // 0..1, upload phase only
  final UploadTaskStatus status;
  final String? errorMessage;
  final String? fileId; // set once the files row exists

  UploadTask({
    required this.id,
    required this.filename,
    required this.fileType,
    this.previewBytes,
    this.progress = 0,
    this.status = UploadTaskStatus.uploading,
    this.errorMessage,
    this.fileId,
  });

  UploadTask copyWith({
    double? progress,
    UploadTaskStatus? status,
    String? errorMessage,
    String? fileId,
  }) {
    return UploadTask(
      id: id,
      filename: filename,
      fileType: fileType,
      previewBytes: previewBytes,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
      fileId: fileId ?? this.fileId,
    );
  }
}
