-- Adds 'image' as a first-class file type, alongside document/audio/video.
-- Images skip the chunking/RAG pipeline entirely (see process-file/index.ts
-- and chat/index.ts) — they're sent as-is to Claude's native vision input
-- when attached to a message, no OCR or embedding step needed.

alter table files drop constraint files_file_type_check;
alter table files add constraint files_file_type_check
  check (file_type in ('document', 'audio', 'video', 'image'));
