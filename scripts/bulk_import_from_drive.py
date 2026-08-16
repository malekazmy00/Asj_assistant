"""
Bulk-imports manual PDFs from Google Drive straight into Medical Engineer
Assistant's Library — no phone/app involved. Designed to run in Google
Colab: mount Drive, fill in the config block below, run.

What it does per file:
  1. Upload the PDF's bytes to Supabase Storage (service-role key, so it
     bypasses the app's normal RLS entirely — this script is trusted).
  2. Insert a `files` row (tagged automatically from its Drive parent
     folder name, unless you override TAG_OVERRIDES below).
  3. Call the `process-file` Edge Function with the new file_id. As of the
     current deployment this returns almost immediately — the actual text
     extraction/chunking/embedding runs in the background on Supabase's
     side, so this script is not what's slow; network + Storage upload is.

Failure handling: each file is fully independent. A bad/corrupt PDF (or a
transient network blip) retries a few times with backoff, then gets logged
as failed and the script moves on — nothing about the batch aborts because
one file is broken. Progress is written to RESULTS_LOG_PATH as it goes
(one JSON line per file), so if Colab disconnects partway through a
~2000-file run, re-running the script skips everything already marked
"ok" in that log and only retries what's left.

Usage in Colab:
    from google.colab import drive
    drive.mount('/content/drive')
    # then edit the CONFIG block below and run this file, e.g.:
    # %run bulk_import_from_drive.py
"""

from __future__ import annotations

import concurrent.futures
import dataclasses
import json
import mimetypes
import os
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

import requests

# ============================================================================
# CONFIG — edit these before running
# ============================================================================

SUPABASE_URL = "https://your-project.supabase.co"
SUPABASE_SERVICE_ROLE_KEY = "your-service-role-key"  # Project Settings -> API

# Folder to scan recursively for PDFs, after drive.mount('/content/drive').
DRIVE_SOURCE_FOLDER = "/content/drive/MyDrive/Manuals"

# Default tag = the file's immediate parent folder name (e.g. a
# "Manuals/GE/xyz.pdf" layout tags everything under GE/ as "GE" — handy if
# your Drive is already loosely organized by brand/device type). Override
# specific folder names here if the auto-derived tag isn't right; leave a
# folder out of this dict to just use its own name.
TAG_OVERRIDES: dict[str, str] = {
    # "Siemens Old": "Siemens",
}

MAX_WORKERS = 6          # concurrent uploads — keep modest, this hits a shared backend
MAX_RETRIES = 3
RETRY_BACKOFF_SECONDS = 3.0

# process-file responds almost immediately and does the real work (text
# extraction, chunking, embedding) in the background — so a fast response
# from it only means "queued", not "succeeded". This script polls for the
# real outcome afterward rather than reporting queued as done.
POLL_INTERVAL_SECONDS = 20
POLL_MAX_WAIT_SECONDS = 3600  # give up waiting after this long; still-pending
                               # files just haven't finished yet, check later

# Written incrementally; re-running the script reads this first and skips
# anything already marked "ok". Put it on Drive so it survives a Colab
# disconnect, not on the ephemeral local disk.
RESULTS_LOG_PATH = "/content/drive/MyDrive/medical_engineer_assistant_import_log.jsonl"

# ============================================================================
# End of config
# ============================================================================

REST_HEADERS = {
    "apikey": SUPABASE_SERVICE_ROLE_KEY,
    "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
    "Content-Type": "application/json",
    "Prefer": "return=representation",
}

_log_lock = threading.Lock()
_print_lock = threading.Lock()


@dataclass
class ImportResult:
    """Outcome of phase 1 (upload + queue for processing). `ok=True` here
    means "successfully queued", not "successfully processed" — process-file
    now does the real work in the background, so phase 2 below is what
    determines the actual, final outcome."""
    path: str
    ok: bool
    file_id: str | None = None
    error: str | None = None
    phase: str = field(default="upload", init=False)


@dataclass
class ProcessingResult:
    """Outcome of phase 2 (did process-file's background work actually
    succeed). This — not ImportResult.ok — is the true success signal."""
    path: str
    file_id: str
    processing_status: str  # "completed" | "failed" | "timeout"
    error_message: str | None = None
    phase: str = field(default="processing", init=False)


def log_result(result: ImportResult | ProcessingResult) -> None:
    # dataclasses.asdict (not result.__dict__!) — a field with init=False and
    # a plain default lives on the class, not the instance dict, until
    # something assigns it explicitly. asdict() reads via fields()
    # introspection instead, so it always captures the true default.
    with _log_lock:
        with open(RESULTS_LOG_PATH, "a") as f:
            f.write(json.dumps(dataclasses.asdict(result)) + "\n")


def load_already_done() -> set[str]:
    """Paths that fully completed processing on a previous run — safe to
    skip. Anything only queued (or that failed/timed out) is retried."""
    if not os.path.exists(RESULTS_LOG_PATH):
        return set()
    done = set()
    with open(RESULTS_LOG_PATH) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
                if row.get("phase") == "processing" and row.get("processing_status") == "completed":
                    done.add(row["path"])
            except json.JSONDecodeError:
                continue
    return done


def safe_print(*args) -> None:
    with _print_lock:
        print(*args)


def tag_for(pdf_path: Path, root: Path) -> str | None:
    try:
        parent_name = pdf_path.relative_to(root).parts[0] if pdf_path.parent != root else None
    except ValueError:
        parent_name = None
    if parent_name is None:
        return None
    return TAG_OVERRIDES.get(parent_name, parent_name)


def find_pdfs(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*.pdf") if p.is_file())


def get_engineer_id() -> str | None:
    resp = requests.get(
        f"{SUPABASE_URL}/rest/v1/engineers?select=id&limit=1",
        headers=REST_HEADERS,
        timeout=30,
    )
    resp.raise_for_status()
    rows = resp.json()
    return rows[0]["id"] if rows else None


def import_one(pdf_path: Path, root: Path, engineer_id: str | None) -> ImportResult:
    filename = pdf_path.name
    tag = tag_for(pdf_path, root)
    last_error = None

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            data = pdf_path.read_bytes()
            storage_path = f"document/bulk_{int(time.time() * 1000)}_{filename}"

            # 1. Upload bytes to Storage.
            upload_resp = requests.post(
                f"{SUPABASE_URL}/storage/v1/object/uploads/{storage_path}",
                headers={
                    "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
                    "apikey": SUPABASE_SERVICE_ROLE_KEY,
                    "Content-Type": "application/pdf",
                },
                data=data,
                timeout=300,
            )
            upload_resp.raise_for_status()

            # 2. Insert the files row.
            insert_resp = requests.post(
                f"{SUPABASE_URL}/rest/v1/files",
                headers=REST_HEADERS,
                json={
                    "file_type": "document",
                    "filename": filename,
                    "storage_path": storage_path,
                    "mime_type": mimetypes.guess_type(filename)[0] or "application/pdf",
                    "size_bytes": len(data),
                    "tag": tag,
                    "uploaded_by": engineer_id,
                },
                timeout=30,
            )
            insert_resp.raise_for_status()
            file_id = insert_resp.json()[0]["id"]

            # 3. Kick off processing (returns fast; chunking/embedding runs
            # in the background on Supabase's side).
            process_resp = requests.post(
                f"{SUPABASE_URL}/functions/v1/process-file",
                headers={
                    "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
                    "Content-Type": "application/json",
                },
                json={"file_id": file_id},
                timeout=60,
            )
            process_resp.raise_for_status()

            return ImportResult(path=str(pdf_path), ok=True, file_id=file_id)

        except Exception as e:  # noqa: BLE001 - genuinely want to catch+retry anything here
            last_error = f"{type(e).__name__}: {e}"
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_BACKOFF_SECONDS * attempt)

    return ImportResult(path=str(pdf_path), ok=False, error=last_error)


def poll_processing_status(
    queued: dict[str, str],  # file_id -> path
) -> list[ProcessingResult]:
    """Polls until every queued file reaches completed/failed, or gives up
    on the stragglers after POLL_MAX_WAIT_SECONDS (they just haven't
    finished — check the files table later, they're not lost)."""
    remaining = dict(queued)
    results: list[ProcessingResult] = []
    elapsed = 0

    while remaining and elapsed < POLL_MAX_WAIT_SECONDS:
        ids = list(remaining.keys())
        for i in range(0, len(ids), 100):  # keep query URLs reasonably sized
            chunk = ids[i:i + 100]
            resp = requests.get(
                f"{SUPABASE_URL}/rest/v1/files"
                f"?id=in.({','.join(chunk)})&select=id,processing_status,error_message",
                headers=REST_HEADERS,
                timeout=30,
            )
            resp.raise_for_status()
            for row in resp.json():
                if row["processing_status"] in ("completed", "failed"):
                    fid = row["id"]
                    result = ProcessingResult(
                        path=remaining[fid],
                        file_id=fid,
                        processing_status=row["processing_status"],
                        error_message=row.get("error_message"),
                    )
                    results.append(result)
                    log_result(result)
                    del remaining[fid]

        if remaining:
            safe_print(f"Still processing: {len(remaining)} file(s)... "
                       f"(waited {elapsed}s, checking again in {POLL_INTERVAL_SECONDS}s)")
            time.sleep(POLL_INTERVAL_SECONDS)
            elapsed += POLL_INTERVAL_SECONDS

    for fid, path in remaining.items():
        result = ProcessingResult(path=path, file_id=fid, processing_status="timeout")
        results.append(result)
        log_result(result)

    return results


def main() -> None:
    root = Path(DRIVE_SOURCE_FOLDER)
    if not root.exists():
        raise SystemExit(f"Folder not found: {root} — did you mount Drive first?")

    all_pdfs = find_pdfs(root)
    already_done = load_already_done()
    todo = [p for p in all_pdfs if str(p) not in already_done]

    print(f"Found {len(all_pdfs)} PDFs, {len(already_done)} already imported, {len(todo)} to go.")
    if not todo:
        print("Nothing to do.")
        return

    engineer_id = get_engineer_id()

    # Phase 1: upload + queue everything for processing.
    queued: dict[str, str] = {}  # file_id -> path
    queue_failures: list[ImportResult] = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = {pool.submit(import_one, p, root, engineer_id): p for p in todo}
        for i, future in enumerate(concurrent.futures.as_completed(futures), start=1):
            result = future.result()
            log_result(result)
            if result.ok and result.file_id:
                queued[result.file_id] = result.path
            else:
                queue_failures.append(result)
                safe_print(f"[UPLOAD FAILED] {result.path}: {result.error}")
            if i % 25 == 0 or i == len(todo):
                safe_print(f"Upload progress: {i}/{len(todo)} ({len(queued)} queued, {len(queue_failures)} failed)")

    # Phase 2: wait for the background processing (text extraction,
    # chunking, embedding) to actually finish, and find out what really
    # succeeded vs. failed.
    print()
    print(f"All uploads submitted. Waiting for {len(queued)} file(s) to finish processing "
          f"(polling every {POLL_INTERVAL_SECONDS}s)...")
    processing_results = poll_processing_status(queued)

    completed = [r for r in processing_results if r.processing_status == "completed"]
    proc_failed = [r for r in processing_results if r.processing_status == "failed"]
    timed_out = [r for r in processing_results if r.processing_status == "timeout"]

    print()
    print(
        f"Done. {len(completed)} fully processed, {len(queue_failures)} failed to upload, "
        f"{len(proc_failed)} failed during processing, {len(timed_out)} still processing "
        f"(re-run this script later to pick those up)."
    )
    if queue_failures:
        print("\nUpload failures:")
        for f in queue_failures:
            print(f"  - {f.path}: {f.error}")
    if proc_failed:
        print("\nProcessing failures (usually a bad/unreadable PDF):")
        for f in proc_failed:
            print(f"  - {f.path}: {f.error_message}")
    print(f"\nFull log (re-running this script skips anything marked completed): {RESULTS_LOG_PATH}")


if __name__ == "__main__":
    main()
