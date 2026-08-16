-- Lightweight tagging (brand/device type) for documents — simple free-text
-- field, not a taxonomy. Used for Library filtering and to help the agent
-- naturally weight related sources (surfaced in RAG citations, see
-- chat/index.ts) — intentionally kept easy to change later.
alter table files add column tag text;
create index idx_files_tag on files(tag);

-- The 'uploads' bucket had no explicit file_size_limit, so it was silently
-- falling back to Supabase's project-wide default (~50MB) — a very likely
-- cause of "upload failed" on real scanned service-manual PDFs, which
-- routinely exceed that. Raised to 500MB.
update storage.buckets set file_size_limit = 524288000 where id = 'uploads';
