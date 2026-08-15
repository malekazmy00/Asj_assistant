# Medical Engineer Assistant

A private, single-user Flutter app for capturing a medical imaging equipment
maintenance business owner's expertise through natural conversation with an
AI assistant, before it's lost.

## How it's put together

```
app/         Flutter mobile app (Chat + Library tabs)
supabase/
  migrations/  Postgres schema (conversations, messages, files, extracted
               knowledge, pgvector embeddings) — see 0001_init.sql
  functions/   Edge Functions (Deno), hosted by Supabase itself:
    chat/          the conversational loop: Claude + extended thinking +
                    RAG + web search tool
    process-file/  chunks & embeds uploaded documents
    embed/         thin wrapper around Supabase's built-in gte-small
                    embedding model, reused by the chat/process-file
                    functions and by the worker below
worker/      Python WhisperX worker (audio/video transcription) — the one
             piece that needs a persistent server of its own; currently
             stubbed, see worker/README.md
docs/        Setup and deployment notes
```

Why this split: Supabase hosts the database, file storage, and the Edge
Functions for you — no server to run for chat, RAG, or document processing.
WhisperX's dependencies (faster-whisper, pyannote, torch) are too heavy for
an Edge Function, so transcription runs in a small separate worker instead.

## Getting started

See `docs/SETUP.md` for environment variables, running migrations,
deploying Edge Functions, and building the APK.

## Design

White background, Facebook-blue (#1877F2) accents, black text throughout,
2.5px borders. Two tabs: Chat and Library. No login screen — this is a
single-user tool for now, by design (see the brief's explicit v1 scope).
