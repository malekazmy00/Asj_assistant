# WhisperX worker (superseded)

**This worker is no longer used.** Audio/video transcription now runs via
Gemini's native audio understanding directly inside the `process-file` Edge
Function (see `supabase/functions/_shared/gemini_transcribe.ts`) — a plain
HTTPS call needs no separate persistent server, so there's no polling
worker to deploy or keep running anymore. This directory is kept only as a
reference/fallback in case Gemini transcription quality or cost ever makes
switching back to a real WhisperX pipeline worthwhile; it is not part of
the current deployment.

Everything below describes how this worker used to work, before that change.

---

Polls Supabase for queued audio/video uploads and transcribes them. This is
the only piece of Medical Engineer Assistant that needs a persistent server
of its own — everything else runs on Supabase (Postgres, Storage, Edge
Functions).

## Current state: stubbed

`main.py` currently writes one honest placeholder `transcript_segment` per
file (flagged `low_confidence`) instead of running real WhisperX. This
means the full pipeline — upload → queue → "Processing…" status in the
Library screen → "completed" → transcript row present — works end-to-end
and is testable today, without a GPU box to run real transcription on yet.

## Running the stub locally

```bash
cd worker
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # fill in SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY
python main.py
```

It polls every `WORKER_POLL_INTERVAL_SECONDS` (default 15s) for `files`
rows where `file_type in ('audio','video')` and `processing_status =
'pending'`, claims one, "transcribes" it, and marks it `completed`.

## Going from stub to real WhisperX

1. Uncomment the ML dependencies in `requirements.txt` (`whisperx`,
   `faster-whisper`, `pyannote.audio`, `torch`) and install them.
2. Get a Hugging Face token and accept the gated model terms for
   `pyannote/segmentation-3.0` and `pyannote/speaker-diarization-3.1`, then
   set `HF_TOKEN` in `.env`.
3. In `main.py`, replace the `transcribe()` stub with a call into
   `real_pipeline.transcribe_real(audio_bytes)` (already implemented —
   download the file from Storage via `client.storage.from_("uploads")
   .download(file["storage_path"])` first, feed the bytes in).
4. Pick `WHISPER_MODEL_SIZE` for the target hardware — `small`/`medium` are
   reasonable on CPU; `large-v3` wants a GPU. Leave `language` unset to let
   Whisper auto-detect (this trade mixes Egyptian Arabic with English/French
   technical terms); pin `language="ar"` if auto-detect proves unreliable.
5. `LOW_CONFIDENCE_THRESHOLD` controls when a segment gets flagged — the
   agent treats flagged segments as worth double-checking with the user
   rather than trusting blindly, since Egyptian Arabic + jargon will
   regularly trip up ASR confidence.

## Deploying it somewhere persistent

This needs to run continuously, unlike the Edge Functions (which Supabase
hosts for you). Any small always-on box works — a VPS, Render/Railway/Fly.io
worker service, or a spare machine. Point `SUPABASE_URL` /
`SUPABASE_SERVICE_ROLE_KEY` at the project and run `python main.py` (or wrap
it in a systemd service / Docker container for restarts). GPU hosting is
optional but meaningfully faster for `large-v3`.
