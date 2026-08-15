// The `chat` Edge Function: the whole conversational loop.
//
// 1. Persist the user's message.
// 2. Embed it and pull relevant context via pgvector (RAG).
// 3. Call Claude with extended thinking + the web search tool.
// 4. Persist the agent's reply, with thinking stored separately.
// 5. Silently (fire-and-forget) extract knowledge from what the user said.
//
// Holds ANTHROPIC_API_KEY and the Supabase service-role key — this is why
// the heavy lifting happens here rather than in the Flutter client.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, handleOptions, jsonResponse } from "../_shared/cors.ts";
import { callClaude, type ClaudeMessage } from "../_shared/anthropic.ts";
import { buildSystemPrompt } from "../_shared/system_prompt.ts";
import { embed, toPgVector } from "../_shared/embeddings.ts";
import { extractKnowledge } from "../_shared/extract_knowledge.ts";

// deno-lint-ignore no-explicit-any
declare const EdgeRuntime: any;

const MAX_HISTORY_MESSAGES = 40;
const RAG_MATCH_COUNT = 8;
const RAG_MIN_SIMILARITY = 0.45;

Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  try {
    const { conversation_id, content } = await req.json();

    if (!conversation_id || typeof content !== "string" || !content.trim()) {
      return jsonResponse({ error: "conversation_id and non-empty content are required" }, 400);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: engineer } = await supabase
      .from("engineers")
      .select("id")
      .limit(1)
      .maybeSingle();
    const engineerId = engineer?.id ?? null;

    // 1. Persist the user's message.
    const { data: userMessage, error: userInsertError } = await supabase
      .from("messages")
      .insert({
        conversation_id,
        role: "user",
        content,
        author_id: engineerId,
      })
      .select()
      .single();
    if (userInsertError) throw userInsertError;

    // 2. Embed it; retrieve relevant context.
    let ragContext = "";
    try {
      const queryEmbedding = await embed(content);

      await supabase.from("embeddings").insert({
        source_type: "message",
        source_id: userMessage.id,
        content_preview: content.slice(0, 2000),
        embedding: toPgVector(queryEmbedding),
      });

      const { data: matches } = await supabase.rpc("match_embeddings", {
        query_embedding: toPgVector(queryEmbedding),
        match_count: RAG_MATCH_COUNT,
        exclude_source_type: "message",
        exclude_source_id: userMessage.id,
      });

      const relevant = (matches ?? []).filter(
        // deno-lint-ignore no-explicit-any
        (m: any) => m.similarity >= RAG_MIN_SIMILARITY,
      );

      if (relevant.length > 0) {
        const lines = relevant
          // deno-lint-ignore no-explicit-any
          .map((m: any) => `- ${m.content_preview}`)
          .join("\n");
        ragContext =
          `\n# Things you already know that might be relevant right now\n` +
          `(Use this naturally if it fits the moment — don't recite it verbatim, and don't force a connection that isn't there.)\n${lines}\n`;
      }
    } catch (e) {
      console.error("RAG retrieval failed, continuing without context:", e);
    }

    // 3. Build history and call Claude.
    const { data: historyRows, error: historyError } = await supabase
      .from("messages")
      .select("role, content")
      .eq("conversation_id", conversation_id)
      .order("created_at", { ascending: true })
      .limit(MAX_HISTORY_MESSAGES);
    if (historyError) throw historyError;

    const claudeMessages: ClaudeMessage[] = (historyRows ?? []).map((m) => ({
      role: m.role === "agent" ? "assistant" : "user",
      content: m.content,
    }));

    const systemPrompt = buildSystemPrompt(ragContext);
    const result = await callClaude({ systemPrompt, messages: claudeMessages });

    const finalText = result.finalText.trim() ||
      "Sorry, I didn't catch that — could you say it again?";

    // 4. Persist the agent's reply, thinking stored separately.
    const { data: agentMessage, error: agentInsertError } = await supabase
      .from("messages")
      .insert({
        conversation_id,
        role: "agent",
        content: finalText,
        thinking_content: result.thinkingText || null,
        metadata: {
          web_search_used: result.webSearchUsed,
          citations: result.citations,
        },
      })
      .select()
      .single();
    if (agentInsertError) throw agentInsertError;

    // Embed the agent's reply too, so future turns can retrieve it.
    embed(finalText)
      .then((vec) =>
        supabase.from("embeddings").insert({
          source_type: "message",
          source_id: agentMessage.id,
          content_preview: finalText.slice(0, 2000),
          embedding: toPgVector(vec),
        })
      )
      .catch((e) => console.error("Failed to embed agent reply:", e));

    // 5. Silent knowledge extraction — never blocks the response.
    const backgroundWork = (async () => {
      try {
        const facts = await extractKnowledge(content);
        for (const fact of facts) {
          const { data: knowledgeRow, error } = await supabase
            .from("extracted_knowledge")
            .insert({
              content: fact.content,
              topic: fact.topic,
              source_type: "message",
              source_message_id: userMessage.id,
              conversation_id,
              stated_by: engineerId,
              stated_at: userMessage.created_at,
            })
            .select()
            .single();
          if (error || !knowledgeRow) continue;

          try {
            const vec = await embed(fact.content);
            await supabase.from("embeddings").insert({
              source_type: "extracted_knowledge",
              source_id: knowledgeRow.id,
              content_preview: fact.content.slice(0, 2000),
              embedding: toPgVector(vec),
            });
          } catch (e) {
            console.error("Failed to embed extracted fact:", e);
          }
        }
      } catch (e) {
        console.error("Knowledge extraction failed:", e);
      }
    })();

    if (typeof EdgeRuntime !== "undefined") {
      EdgeRuntime.waitUntil(backgroundWork);
    } else {
      // Local `supabase functions serve` doesn't have EdgeRuntime; just await.
      await backgroundWork;
    }

    return jsonResponse({ message: agentMessage });
  } catch (error) {
    console.error("chat function error:", error);
    return new Response(
      JSON.stringify({ error: (error as Error).message ?? String(error) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
