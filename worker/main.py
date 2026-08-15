"""
Medical Engineer Assistant — audio/video transcription worker.

Polls the `files` table for queued audio/video uploads and processes them.
This is the ONE piece of the system that needs a real, persistent server
(WhisperX's dependencies are too heavy for a Deno Edge Function) — see
README.md for deployment options.

Current state: STUBBED. `transcribe()` below writes one honest placeholder
transcript_segment (flagged low_confidence) instead of running real
WhisperX, so the rest of the pipeline — job queue, status tracking, Library
UI, embeddings — is fully exercised end-to-end without pretending to have
real transcription. Swap `transcribe()` for `transcribe_real()` (stubbed
further down, with the full WhisperX/pyannote pipeline structure and
comments) once this worker has a home to run on.
"""

import os
import time
import logging
from datetime import datetime, timezone

import httpx
from dotenv import load_dotenv
from supabase import create_client, Client

load_dotenv()

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("worker")

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_SERVICE_ROLE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
POLL_INTERVAL_SECONDS = int(os.environ.get("WORKER_POLL_INTERVAL_SECONDS", "15"))
EMBED_FUNCTION_URL = f"{SUPABASE_URL}/functions/v1/embed"

client: Client = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)


def claim_next_file() -> dict | None:
    """Atomically claims one pending audio/video file (pending -> processing),
    so multiple worker instances never double-process the same upload."""
    candidates = (
        client.table("files")
        .select("id, storage_path, file_type, filename, mime_type")
        .in_("file_type", ["audio", "video"])
        .eq("processing_status", "pending")
        .order("uploaded_at")
        .limit(5)
        .execute()
    )
    for candidate in candidates.data:
        claim = (
            client.table("files")
            .update({"processing_status": "processing"})
            .eq("id", candidate["id"])
            .eq("processing_status", "pending")
            .execute()
        )
        if claim.data:
            return candidate
    return None


def transcribe(file: dict) -> list[dict]:
    """STUB — replace with transcribe_real() once WhisperX is wired in."""
    return [
        {
            "start_time": 0,
            "end_time": 0,
            "speaker_label": None,
            "text": (
                "[Automatic transcription is not yet enabled for this deployment. "
                "This is a placeholder — see worker/README.md to turn on the real "
                "WhisperX pipeline.]"
            ),
            "confidence": None,
            "low_confidence": True,
        }
    ]


def embed_text(text: str) -> list[float] | None:
    """Calls the `embed` Edge Function (Supabase's built-in gte-small model)
    so transcript embeddings stay dimensionally consistent (384-d) with
    everything else in the `embeddings` table."""
    try:
        response = httpx.post(
            EMBED_FUNCTION_URL,
            json={"text": text},
            headers={"Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}"},
            timeout=30,
        )
        response.raise_for_status()
        return response.json()["embedding"]
    except Exception:
        log.exception("Failed to embed transcript segment")
        return None


def process_file(file: dict) -> None:
    log.info("Processing file %s (%s)", file["id"], file["filename"])
    try:
        segments = transcribe(file)

        for index, segment in enumerate(segments):
            row = (
                client.table("transcript_segments")
                .insert(
                    {
                        "file_id": file["id"],
                        "segment_index": index,
                        "speaker_label": segment.get("speaker_label"),
                        "start_time": segment["start_time"],
                        "end_time": segment["end_time"],
                        "text": segment["text"],
                        "confidence": segment.get("confidence"),
                        "low_confidence": segment.get("low_confidence", False),
                    }
                )
                .execute()
            )
            segment_row = row.data[0]

            # Only embed real transcript content — never the stub placeholder
            # text, so it can't leak into the agent's retrieved context.
            if not segment.get("low_confidence") or segment.get("confidence") is not None:
                embedding = embed_text(segment["text"])
                if embedding is not None:
                    client.table("embeddings").insert(
                        {
                            "source_type": "transcript_segment",
                            "source_id": segment_row["id"],
                            "content_preview": segment["text"][:2000],
                            "embedding": embedding,
                        }
                    ).execute()

        client.table("files").update(
            {
                "processing_status": "completed",
                "processed_at": datetime.now(timezone.utc).isoformat(),
            }
        ).eq("id", file["id"]).execute()
        log.info("Completed file %s", file["id"])

    except Exception as e:
        log.exception("Failed to process file %s", file["id"])
        client.table("files").update(
            {"processing_status": "failed", "error_message": str(e)}
        ).eq("id", file["id"]).execute()


def main() -> None:
    log.info("Worker started. Polling every %ss.", POLL_INTERVAL_SECONDS)
    while True:
        try:
            file = claim_next_file()
            if file:
                process_file(file)
                continue  # check for another immediately
        except Exception:
            log.exception("Poll loop error")
        time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
