-- Sourcing overhaul: lets the agent read a full authoritative document
-- (not just a search snippet) when it decides one is worth it, cache that
-- content for future questions, rank it by trust tier, and flag
-- contradictions instead of silently overwriting. See chat/index.ts's
-- fetch_full_document / flag_source_conflict tools.

-- ============================================================================
-- web_source_chunks — full text of web-fetched authoritative sources,
-- chunked and embedded the same way uploaded documents are (see
-- document_chunks), so future questions on the same topic pull from our
-- own verified store first instead of re-searching and re-risking a
-- shallow snippet read. Not tied to a `files` row — this is external web
-- content the agent decided to read in full, not something the user
-- uploaded.
-- ============================================================================
create table web_source_chunks (
  id            uuid primary key default gen_random_uuid(),
  source_url    text not null,
  source_title  text,
  -- Storage/ranking tier (finer-grained than the manual/official/inference
  -- label the agent shows in chat — see system_prompt.ts's "Citing what
  -- you know" section): official manual > manufacturer's own site/brochure
  -- > authorized distributor > general marketplace/forum/scribd-type upload.
  trust_tier    text not null check (trust_tier in ('manual', 'official', 'distributor', 'marketplace')),
  chunk_index   int not null,
  content       text not null,
  fetched_at    timestamptz not null default now(),
  unique (source_url, chunk_index)
);

create index idx_web_source_chunks_url on web_source_chunks(source_url);
create index idx_web_source_chunks_tier on web_source_chunks(trust_tier);

-- Extend embeddings' polymorphic source_type to cover the new table.
alter table embeddings drop constraint embeddings_source_type_check;
alter table embeddings add constraint embeddings_source_type_check
  check (source_type in ('message', 'extracted_knowledge', 'document_chunk', 'transcript_segment', 'web_source_chunk'));

-- ============================================================================
-- source_conflicts — when a newly-fetched official/manual-tier source
-- contradicts something already stored at official/manual tier, this
-- records it for review instead of silently overwriting or silently
-- picking one. No review UI yet (single-user app, kept simple per the
-- original brief's "no automated verification pipeline") — the agent
-- also says so out loud in the conversation when it flags one; this table
-- is the durable record of it.
-- ============================================================================
create table source_conflicts (
  id                uuid primary key default gen_random_uuid(),
  existing_chunk_id uuid references web_source_chunks(id) on delete set null,
  new_chunk_id      uuid references web_source_chunks(id) on delete set null,
  description       text not null,
  resolved          boolean not null default false,
  created_at        timestamptz not null default now()
);

create index idx_source_conflicts_unresolved on source_conflicts(resolved) where not resolved;

-- ============================================================================
-- perf_logs — step-by-step timing for one chat turn, so a slow response
-- can be diagnosed with real numbers (which step, how long) instead of
-- guessing.
-- ============================================================================
create table perf_logs (
  id               uuid primary key default gen_random_uuid(),
  created_at       timestamptz not null default now(),
  conversation_id  uuid references conversations(id) on delete set null,
  message_id       uuid references messages(id) on delete set null,
  step             text not null,   -- e.g. 'rag_retrieval', 'claude_call', 'fetch_full_document', 'embeddings_write'
  duration_ms      int not null,
  metadata         jsonb not null default '{}'::jsonb
);

create index idx_perf_logs_created_at on perf_logs(created_at desc);
create index idx_perf_logs_step on perf_logs(step);

-- RLS: all three are written exclusively by the `chat` Edge Function
-- (service-role key) — never directly by the Flutter client, unlike
-- error_logs. No anon policies at all, matching extracted_knowledge/embeddings.
alter table web_source_chunks enable row level security;
alter table source_conflicts enable row level security;
alter table perf_logs enable row level security;
