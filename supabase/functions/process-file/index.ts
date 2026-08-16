// The `process-file` Edge Function: kicked off right after a client upload.
//
// - documents: download from Storage, extract text, chunk it, embed each
//   chunk, mark the file completed (or failed with a reason).
// - audio/video: nothing to do here — they stay `pending` and are picked up
//   by the separate WhisperX worker (see /worker), which owns transcription.
// - images: nothing to do here either — no OCR/chunking step. Images go
//   straight to Claude's native vision input when attached to a chat
//   message (see chat/index.ts), so they're marked completed immediately
//   (the Flutter client actually does this at upload time and doesn't call
//   this function for images at all — this branch exists as a safety net).

import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, handleOptions, jsonResponse } from "../_shared/cors.ts";
import { embed, toPgVector } from "../_shared/embeddings.ts";
import { extractText } from "../_shared/extract_text.ts";
import { chunkText } from "../_shared/chunk_text.ts";

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

    if (file.file_type !== "document") {
      // Audio/video: leave as `pending` for the WhisperX worker to pick up.
      return jsonResponse({ status: "queued_for_worker" });
    }

    await supabase.from("files").update({ processing_status: "processing" }).eq("id", file_id);

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

      for (let i = 0; i < chunks.length; i++) {
        const { data: chunkRow, error: chunkError } = await supabase
          .from("document_chunks")
          .insert({ file_id, chunk_index: i, content: chunks[i] })
          .select()
          .single();
        if (chunkError) throw chunkError;

        const vec = await embed(chunks[i]);
        await supabase.from("embeddings").insert({
          source_type: "document_chunk",
          source_id: chunkRow.id,
          content_preview: chunks[i].slice(0, 2000),
          embedding: toPgVector(vec),
        });
      }

      await supabase
        .from("files")
        .update({ processing_status: "completed", processed_at: new Date().toISOString() })
        .eq("id", file_id);

      return jsonResponse({ status: "completed", chunks: chunks.length });
    } catch (processingError) {
      await supabase
        .from("files")
        .update({
          processing_status: "failed",
          error_message: (processingError as Error).message ?? String(processingError),
        })
        .eq("id", file_id);
      throw processingError;
    }
  } catch (error) {
    console.error("process-file function error:", error);
    return new Response(
      JSON.stringify({ error: (error as Error).message ?? String(error) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
