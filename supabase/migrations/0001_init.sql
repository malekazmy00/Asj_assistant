-- Medical Engineer Assistant — initial schema (v1, single-user)
--
-- Design notes:
--   * Single-user for v1: there is no auth.users integration. The `engineers`
--     table exists purely so every piece of content has a real attribution
--     FK from day one (who said/uploaded/created it, and when), so that
--     multi-user support later is a matter of adding rows + auth, not a
--     schema rewrite. A single row is seeded below for the business owner.
--   * `extracted_knowledge.verification_status` is an internal/admin concept.
--     It is never read by the chat UI — only the Library screen's badge and
--     any future admin views should touch it.
--   * Embeddings are generated with Supabase Edge Runtime's built-in
--     `gte-small` model (384 dimensions) so no external embeddings API key
--     is required. If a different embedding model is adopted later, add a
--     new embeddings table/column rather than reusing this one at a
--     different dimensionality.
--   * RLS is enabled everywhere for good hygiene, but v1 policies are
--     deliberately permissive (single user, no login). Tighten these when
--     real auth/multi-user/sharing rules are introduced — search this file
--     for "TIGHTEN LATER".

-- ============================================================================
-- Extensions
-- ============================================================================
create extension if not exists pgcrypto;   -- gen_random_uuid()
create extension if not exists vector;     -- pgvector

-- ============================================================================
-- Helper: updated_at trigger
-- ============================================================================
create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================================
-- engineers — attribution, seeded with one row for v1. Ready to grow into a
-- real users table (add auth linkage, roles, etc.) without touching callers.
-- ============================================================================
create table engineers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  email       text,
  created_at  timestamptz not null default now()
);

comment on table engineers is
  'Attribution identity. Single row in v1 (the business owner). Multi-user '
  'later = more rows + auth, not a schema change.';

-- ============================================================================
-- conversations — chat sessions
-- ============================================================================
create table conversations (
  id              uuid primary key default gen_random_uuid(),
  title           text,
  owner_id        uuid references engineers(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  last_message_at timestamptz
);

create trigger trg_conversations_updated_at
  before update on conversations
  for each row execute function set_updated_at();

-- ============================================================================
-- messages — every turn, stored in full. Nothing is ever discarded: the
-- extended-thinking content is persisted separately from the visible answer.
-- ============================================================================
create table messages (
  id                uuid primary key default gen_random_uuid(),
  conversation_id   uuid not null references conversations(id) on delete cascade,
  role              text not null check (role in ('user', 'agent')),
  content           text not null,
  thinking_content  text,              -- agent-only; raw extended-thinking output
  author_id         uuid references engineers(id),  -- who sent it (user messages)
  metadata          jsonb not null default '{}'::jsonb, -- tool calls, web search hits, etc.
  created_at        timestamptz not null default now()
);

create index idx_messages_conversation_id on messages(conversation_id, created_at);

-- Keep conversations.last_message_at fresh for sorting the chat list.
create or replace function touch_conversation_last_message()
returns trigger
language plpgsql
as $$
begin
  update conversations
    set last_message_at = new.created_at
    where id = new.conversation_id;
  return new;
end;
$$;

create trigger trg_messages_touch_conversation
  after insert on messages
  for each row execute function touch_conversation_last_message();

-- ============================================================================
-- files — uploaded documents / audio / video
-- ============================================================================
create table files (
  id                 uuid primary key default gen_random_uuid(),
  conversation_id    uuid references conversations(id) on delete set null,
  message_id         uuid references messages(id) on delete set null, -- the chat message it was attached to
  file_type          text not null check (file_type in ('document', 'audio', 'video')),
  filename           text not null,
  storage_path       text not null,     -- path inside the Supabase Storage bucket
  mime_type          text,
  size_bytes         bigint,
  duration_seconds   numeric,           -- audio/video only
  processing_status  text not null default 'pending'
                       check (processing_status in ('pending', 'processing', 'completed', 'failed')),
  error_message      text,
  uploaded_by        uuid references engineers(id),
  uploaded_at        timestamptz not null default now(),
  processed_at       timestamptz,
  -- Internal/admin concept, same as extracted_knowledge.verification_status
  -- (independent per file, not derived — a file can carry several facts of
  -- mixed verification). Shown only as a badge on the Library screen, which
  -- is explicitly an admin-only view; never referenced in the chat UI.
  verification_status text not null default 'unverified'
                       check (verification_status in ('verified', 'unverified'))
);

create index idx_files_type_status on files(file_type, processing_status);
create index idx_files_conversation_id on files(conversation_id);

-- ============================================================================
-- document_chunks — chunked text from uploaded documents, for RAG
-- ============================================================================
create table document_chunks (
  id          uuid primary key default gen_random_uuid(),
  file_id     uuid not null references files(id) on delete cascade,
  chunk_index int not null,
  content     text not null,
  created_at  timestamptz not null default now(),
  unique (file_id, chunk_index)
);

-- ============================================================================
-- transcript_segments — WhisperX output for audio/video (speaker-labelled).
-- Kept separate from document_chunks because transcripts carry extra
-- structure (speaker, timing, confidence) the agent needs to reason about
-- ("this bit sounds unclear, let me confirm with you").
-- ============================================================================
create table transcript_segments (
  id              uuid primary key default gen_random_uuid(),
  file_id         uuid not null references files(id) on delete cascade,
  segment_index   int not null,
  speaker_label   text,               -- e.g. "SPEAKER_00" from diarization
  start_time      numeric not null,
  end_time        numeric not null,
  text            text not null,
  confidence      numeric,            -- avg word-confidence from WhisperX, 0..1
  low_confidence  boolean not null default false, -- worth double-checking with the user
  created_at      timestamptz not null default now(),
  unique (file_id, segment_index)
);

create index idx_transcript_segments_file_id on transcript_segments(file_id);
create index idx_transcript_segments_low_confidence
  on transcript_segments(file_id) where low_confidence;

-- ============================================================================
-- extracted_knowledge — distilled facts, with full attribution + a
-- verification flag that is internal/admin-only (never shown in chat UI).
-- ============================================================================
create table extracted_knowledge (
  id                   uuid primary key default gen_random_uuid(),
  content              text not null,
  topic                text,                 -- free-text category, e.g. equipment/brand — helps
                                              -- future topic-based sharing rules
  source_type          text not null check (source_type in ('message', 'file', 'conversation')),
  source_message_id    uuid references messages(id) on delete set null,
  source_file_id       uuid references files(id) on delete set null,
  conversation_id      uuid references conversations(id) on delete set null,
  stated_by            uuid references engineers(id),   -- full attribution, day one
  stated_at            timestamptz not null default now(),
  verification_status  text not null default 'unverified'
                          check (verification_status in ('verified', 'unverified')),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

comment on column extracted_knowledge.verification_status is
  'Internal/admin concept only. Must never be surfaced or referenced in the '
  'chat UI. Default unverified until corroborated.';

create trigger trg_extracted_knowledge_updated_at
  before update on extracted_knowledge
  for each row execute function set_updated_at();

create index idx_extracted_knowledge_conversation_id on extracted_knowledge(conversation_id);
create index idx_extracted_knowledge_topic on extracted_knowledge(topic);

-- ============================================================================
-- embeddings — pgvector, linked polymorphically to messages, extracted
-- knowledge, document chunks, and transcript segments, for retrieval.
-- 384 dims = Supabase Edge Runtime's built-in `gte-small` model.
-- ============================================================================
create table embeddings (
  id               uuid primary key default gen_random_uuid(),
  source_type      text not null check (source_type in
                       ('message', 'extracted_knowledge', 'document_chunk', 'transcript_segment')),
  source_id        uuid not null,
  content_preview  text not null,   -- denormalized copy of the embedded text
  embedding        vector(384) not null,
  created_at       timestamptz not null default now(),
  unique (source_type, source_id)
);

create index idx_embeddings_hnsw
  on embeddings using hnsw (embedding vector_cosine_ops);

-- Nearest-neighbour lookup for RAG. content_preview is denormalized onto
-- embeddings specifically so retrieval never needs to join back to the
-- source tables (and, in particular, never touches extracted_knowledge's
-- verification_status).
create or replace function match_embeddings(
  query_embedding vector(384),
  match_count int default 8,
  exclude_source_type text default null,
  exclude_source_id uuid default null
)
returns table (
  source_type text,
  source_id text,
  content_preview text,
  similarity float
)
language sql stable
as $$
  select source_type, source_id::text, content_preview,
         1 - (embedding <=> query_embedding) as similarity
  from embeddings
  where exclude_source_id is null
     or not (source_type = exclude_source_type and source_id = exclude_source_id)
  order by embedding <=> query_embedding
  limit match_count;
$$;

-- ============================================================================
-- Storage bucket for uploaded files (private; the app signs/uses it via API)
-- ============================================================================
insert into storage.buckets (id, name, public)
values ('uploads', 'uploads', false)
on conflict (id) do nothing;

-- ============================================================================
-- Row Level Security
--
-- v1 is single-user with no login screen, so the Flutter app authenticates
-- to Supabase with the anon key and these policies are intentionally
-- permissive for the tables it needs direct read/write access to.
-- extracted_knowledge and embeddings get NO anon policies at all — they are
-- reachable only via the service-role key from Edge Functions, which is the
-- simplest guarantee that verification status/internal bookkeeping never
-- leaks into the client. TIGHTEN LATER when real auth ships.
-- ============================================================================
alter table engineers enable row level security;
alter table conversations enable row level security;
alter table messages enable row level security;
alter table files enable row level security;
alter table document_chunks enable row level security;
alter table transcript_segments enable row level security;
alter table extracted_knowledge enable row level security;
alter table embeddings enable row level security;

-- TIGHTEN LATER: scope these to the authenticated user once auth exists.
create policy "v1 anon full access" on engineers
  for all to anon using (true) with check (true);
create policy "v1 anon full access" on conversations
  for all to anon using (true) with check (true);
create policy "v1 anon full access" on messages
  for all to anon using (true) with check (true);
create policy "v1 anon full access" on files
  for all to anon using (true) with check (true);
create policy "v1 anon full access" on document_chunks
  for all to anon using (true) with check (true);
create policy "v1 anon full access" on transcript_segments
  for all to anon using (true) with check (true);

-- extracted_knowledge and embeddings: no anon policies (service-role only).

create policy "v1 anon uploads bucket" on storage.objects
  for all to anon
  using (bucket_id = 'uploads')
  with check (bucket_id = 'uploads');

-- ============================================================================
-- Seed: one engineer row for the business owner. Edit the name/email later
-- via SQL or a future settings screen.
-- ============================================================================
insert into engineers (name, email)
values ('Business Owner', 'elkhateebaly8@gmail.com');
