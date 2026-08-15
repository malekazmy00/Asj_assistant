// Tiny HTTP wrapper around the shared `embed()` helper (Supabase Edge
// Runtime's built-in gte-small model), so non-Deno callers — namely the
// WhisperX worker — can get a 384-dim embedding for a piece of text without
// re-implementing or duplicating the model choice.

import { corsHeaders, handleOptions, jsonResponse } from "../_shared/cors.ts";
import { embed } from "../_shared/embeddings.ts";

Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  try {
    const { text } = await req.json();
    if (!text || typeof text !== "string") {
      return jsonResponse({ error: "text is required" }, 400);
    }
    const embedding = await embed(text);
    return jsonResponse({ embedding });
  } catch (error) {
    console.error("embed function error:", error);
    return new Response(
      JSON.stringify({ error: (error as Error).message ?? String(error) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
