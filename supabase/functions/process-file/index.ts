// The `process-file` Edge Function: kicked off right after a client upload
// (or, for bulk imports, called directly with a file already in Storage —
// see worker/bulk_import_from_drive.py).
//
// - documents: download from Storage, extract text, chunk it, embed each
//   chunk, mark the file completed (or failed with a reason).
// - audio/video: download from Storage, transcribe via Gemini (native audio
//   understanding — see _shared/gemini_transcribe.ts), store speaker-
//   labelled segments, embed each one. This replaces the old WhisperX
//   worker (see worker/README.md) — a plain HTTPS call needs no separate
//   persistent server, so it fits right into this same function instead of
//   a polling job elsewhere.
// - images: nothing to do here — no OCR/chunking step. Images go straight
//   to Claude's native vision input when attached to a chat message (see
//   chat/index.ts), so they're marked completed immediately (the Flutter
//   client actually does this at upload time and doesn't call this
//   function for images at all — this branch exists as a safety net).
//
// All of the above runs in the background (EdgeRuntime.waitUntil) rather
// than blocking the response — a large manual or a long call recording can
// take a while, and a slow response here shouldn't risk a request timeout
// for one file or stall a bulk-import script processing thousands of them.
//
// Failure isolation: each call operates on exactly one file_id and only
// ever touches that file's own row — one bad/corrupt file marks itself
// `failed` with a reason and cannot affect any other file's processing,
// which is what makes it safe to fire this at a large batch of files and
// just retry the individual failures.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, handleOptions, jsonResponse } from "../_shared/cors.ts";
import { embed, toPgVector } from "../_shared/embeddings.ts";
import { extractText } from "../_shared/extract_text.ts";
import { chunkText } from "../_shared/chunk_text.ts";
import { transcribeWithGemini } from "../_shared/gemini_transcribe.ts";
import { maybePostRecordingKickoff } from "../_shared/recording_kickoff.ts";

// deno-lint-ignore no-explicit-any
declare const EdgeRuntime: any;
// deno-lint-ignore no-explicit-any
type SupabaseClient = any;
// deno-lint-ignore no-explicit-any
type FileRow = any;

Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  try {
    const { file_id } = await req.json();
    if (!file_id) return jsonResponse({ error: "file_id is required" }, 400);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: file, error: fileError } = await supabase
      .from("files")
      .select("*")
      .eq("id", file_id)
      .single();
    if (fileError) throw fileError;

    if (file.file_type === "image") {
      await supabase
        .from("files")
        .update({ processing_status: "completed", processed_at: new Date().toISOString() })
        .eq("id", file_id);
      return jsonResponse({ status: "completed" });
    }

    if (file.file_type !== "document" && file.file_type !== "audio" && file.file_type !== "video") {
      return jsonResponse({ error: `Unexpected file_type: ${file.file_type}` }, 400);
    }

    await supabase.from("files").update({ processing_status: "processing" }).eq("id", file_id);

    const backgroundWork = file.file_type === "document"
      ? processDocument(supabase, file)
      : processAudioVideo(supabase, file);
    if (typeof EdgeRuntime !== "undefined") {
      EdgeRuntime.waitUntil(backgroundWork);
    } else {
      // Local `supabase functions serve` doesn't have EdgeRuntime; just await.
      await backgroundWork;
    }

    return jsonResponse({ status: "processing" });
  } catch (error) {
    console.error("process-file function error:", error);
    return new Response(
      JSON.stringify({ error: (error as Error).message ?? String(error) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});

async function processDocument(supabase: SupabaseClient, file: FileRow): Promise<void> {
  try {
    const { data: blob, error: downloadError } = await supabase.storage
      .from("uploads")
      .download(file.storage_path);
    if (downloadError) throw downloadError;

    const bytes = new Uint8Array(await blob.arrayBuffer());
    const text = await extractText(bytes, file.mime_type ?? "", file.filename);

    if (!text.trim()) {
      throw new Error("No extractable text found in this document.");
    }

    const chunks = chunkText(text);

    // Sequential on purpose for now (simplicity/predictability over
    // throughput) — fine for background processing; parallelize with
    // bounded concurrency later if very large manuals prove slow.
    for (let i = 0; i < chunks.length; i++) {
      const { data: chunkRow, error: chunkError } = await supabase
        .from("document_chunks")
        .insert({ file_id: file.id, chunk_index: i, content: chunks[i] })
        .select()
        .single();
      if (chunkError) throw chunkError;

      const vec = await embed(chunks[i]);
      await supabase.from("embeddings").upsert({
        source_type: "document_chunk",
        source_id: chunkRow.id,
        content_preview: chunks[i].slice(0, 2000),
        embedding: toPgVector(vec),
      }, { onConflict: "source_type,source_id" });
    }

    await supabase
      .from("files")
      .update({ processing_status: "completed", processed_at: new Date().toISOString() })
      .eq("id", file.id);
  } catch (processingError) {
    console.error(`process-file background error for ${file.id}:`, processingError);
    await supabase
      .from("files")
      .update({
        processing_status: "failed",
        error_message: (processingError as Error).message ?? String(processingError),
      })
      .eq("id", file.id);
  }
}

async function processAudioVideo(supabase: SupabaseClient, file: FileRow): Promise<void> {
  try {
    const { data: blob, error: downloadError } = await supabase.storage
      .from("uploads")
      .download(file.storage_path);
    if (downloadError) throw downloadError;

    const bytes = new Uint8Array(await blob.arrayBuffer());
    const mimeType = file.mime_type || (file.file_type === "video" ? "video/mp4" : "audio/mpeg");
    const segments = await transcribeWithGemini(bytes, mimeType, file.filename);

    if (segments.length === 0) {
      throw new Error("Gemini returned an empty transcript — the recording may be silent or unreadable.");
    }

    for (let i = 0; i < segments.length; i++) {
      const seg = segments[i];
      const { data: segmentRow, error: segmentError } = await supabase
        .from("transcript_segments")
        .insert({
          file_id: file.id,
          segment_index: i,
          speaker_label: seg.speaker_label,
          start_time: seg.start_time,
          end_time: seg.end_time,
          text: seg.text,
          confidence: null, // Gemini doesn't expose a numeric score — low_confidence is its own flag
          low_confidence: seg.low_confidence,
        })
        .select()
        .single();
      if (segmentError) throw segmentError;

      try {
        const vec = await embed(seg.text);
        await supabase.from("embeddings").upsert({
          source_type: "transcript_segment",
          source_id: segmentRow.id,
          content_preview: seg.text.slice(0, 2000),
          embedding: toPgVector(vec),
        }, { onConflict: "source_type,source_id" });
      } catch (e) {
        console.error(`Failed to embed transcript segment ${segmentRow.id}:`, e);
      }
    }

    await supabase
      .from("files")
      .update({ processing_status: "completed", processed_at: new Date().toISOString() })
      .eq("id", file.id);

    await maybePostRecordingKickoff(supabase, file, { status: "completed", segments })
      .catch((e) => console.error(`Recording kickoff failed for ${file.id} (non-fatal):`, e));
  } catch (processingError) {
    const message = (processingError as Error).message ?? String(processingError);
    console.error(`process-file audio/video error for ${file.id}:`, processingError);
    await supabase
      .from("files")
      .update({ processing_status: "failed", error_message: message })
      .eq("id", file.id);

    await maybePostRecordingKickoff(supabase, file, { status: "failed", errorMessage: message })
      .catch((e) => console.error(`Recording kickoff failed for ${file.id} (non-fatal):`, e));
  }
}
