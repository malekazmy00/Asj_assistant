// Quick, ephemeral transcription for the chat composer's mic button —
// distinct from call-recording processing (process-file/index.ts): no
// files row, no Storage persistence, no transcript_segments/embeddings,
// no dedicated chat. The audio exists only for the duration of this
// request; the client gets back plain text to drop into the message box
// for the user to review and send like anything else they typed.
//
// Replaces the old on-device speech_to_text live-recognition path, which
// had an unfixable-from-our-side crash (see third_party/speech_to_text/
// PATCH_NOTES.md) — recording a short clip and sending it here reuses the
// same Gemini transcription already proven out for call recordings
// instead.

import { corsHeaders, handleOptions, jsonResponse } from "../_shared/cors.ts";
import { transcribeWithGemini } from "../_shared/gemini_transcribe.ts";
import { decodeBase64 } from "jsr:@std/encoding@1/base64";

Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  try {
    const { audio_base64, mime_type } = await req.json();
    if (typeof audio_base64 !== "string" || !audio_base64) {
      return jsonResponse({ error: "audio_base64 is required" }, 400);
    }
    const mimeType = typeof mime_type === "string" && mime_type ? mime_type : "audio/mp4";

    const bytes = decodeBase64(audio_base64);
    const segments = await transcribeWithGemini(bytes, mimeType, "voice_message");

    const transcript = segments.map((s) => s.text.trim()).filter(Boolean).join(" ").trim();
    if (!transcript) {
      return jsonResponse({ error: "Couldn't make out any speech in that recording." }, 422);
    }

    return jsonResponse({ transcript });
  } catch (error) {
    console.error("transcribe-voice-message error:", error);
    return new Response(
      JSON.stringify({ error: (error as Error).message ?? String(error) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
