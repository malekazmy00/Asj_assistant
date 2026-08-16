// The `chat` Edge Function: the whole conversational loop.
//
// 1. Persist the user's message (idempotently — see below), including any
//    image attachments.
// 2. Embed it and pull relevant context via pgvector (RAG).
// 3. Call Claude with extended thinking, the web search tool, and any
//    images — this turn's and, within the history window, earlier ones too.
// 4. Persist the agent's reply, with thinking stored separately.
// 5. Silently (fire-and-forget) extract knowledge from what the user said.
//
// Holds ANTHROPIC_API_KEY and the Supabase service-role key — this is why
// the heavy lifting happens here rather than in the Flutter client.
//
// Idempotent retries: the client generates the message id itself
// (`client_message_id`) and resends the *same* id if a send fails or times
// out client-side. That lets us tell "never reached the server" apart from
// "reached the server but the response got lost" and resume correctly
// instead of ever creating a duplicate user message or double-calling
// Claude for the same turn.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, handleOptions, jsonResponse } from "../_shared/cors.ts";
import { callClaude, type ClaudeContentBlock, type ClaudeMessage } from "../_shared/anthropic.ts";
import { buildSystemPrompt } from "../_shared/system_prompt.ts";
import { embed, toPgVector } from "../_shared/embeddings.ts";
import { extractKnowledge } from "../_shared/extract_knowledge.ts";
import { buildImageBlocks, fetchImageFiles } from "../_shared/attachments.ts";

// deno-lint-ignore no-explicit-any
declare const EdgeRuntime: any;

const MAX_HISTORY_MESSAGES = 40;
const RAG_MATCH_COUNT = 8;
const RAG_MIN_SIMILARITY = 0.45;

Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  try {
    const { conversation_id, content, client_message_id, attachment_file_ids } = await req.json();
    const attachmentIds: string[] = Array.isArray(attachment_file_ids) ? attachment_file_ids : [];
    const text: string = typeof content === "string" ? content : "";

    if (!conversation_id || (!text.trim() && attachmentIds.length === 0)) {
      return jsonResponse(
        { error: "conversation_id and (non-empty content or attachment_file_ids) are required" },
        400,
      );
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

    // 1. Persist the user's message — idempotently if a client_message_id
    // was supplied (a retry of an earlier attempt).
    let userMessage;
    if (client_message_id) {
      const { data: existing } = await supabase
        .from("messages")
        .select()
        .eq("id", client_message_id)
        .eq("conversation_id", conversation_id)
        .maybeSingle();

      if (existing) {
        // Already reached the server before. Did it also already get a
        // reply? If so, this is a pure retry of a successful turn whose
        // response never made it back to the client — return the same
        // reply rather than calling Claude again.
        const { data: existingReply } = await supabase
          .from("messages")
          .select()
          .eq("replies_to_message_id", existing.id)
          .maybeSingle();

        if (existingReply) {
          return jsonResponse({ message: existingReply });
        }
        // User message landed but the reply never got generated — resume
        // from here instead of re-inserting.
        userMessage = existing;
      }
    }

    if (!userMessage) {
      const insertPayload: Record<string, unknown> = {
        conversation_id,
        role: "user",
        content: text,
        author_id: engineerId,
        metadata: { attachment_file_ids: attachmentIds },
      };
      if (client_message_id) insertPayload.id = client_message_id;

      const { data: inserted, error: userInsertError } = await supabase
        .from("messages")
        .insert(insertPayload)
        .select()
        .single();
      if (userInsertError) throw userInsertError;
      userMessage = inserted;
    }

    // 2. Embed it; retrieve relevant context. (Skip for image-only
    // messages with no text — nothing meaningful to embed.) Upsert since a
    // resumed retry may have already embedded this message in a prior
    // attempt.
    let ragContext = "";
    if (text.trim()) {
      try {
        const queryEmbedding = await embed(text);

        await supabase.from("embeddings").upsert({
          source_type: "message",
          source_id: userMessage.id,
          content_preview: text.slice(0, 2000),
          embedding: toPgVector(queryEmbedding),
        }, { onConflict: "source_type,source_id" });

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
    }

    // 3. Build history — reconstructing image attachments for any message
    // within the window that carried them, not just this turn's — and
    // call Claude.
    const { data: historyRows, error: historyError } = await supabase
      .from("messages")
      .select("role, content, metadata")
      .eq("conversation_id", conversation_id)
      .order("created_at", { ascending: true })
      .limit(MAX_HISTORY_MESSAGES);
    if (historyError) throw historyError;

    const rows = historyRows ?? [];

    const attachmentIdsInHistory = new Set<string>();
    for (const row of rows) {
      const ids = (row.metadata as { attachment_file_ids?: string[] } | null)?.attachment_file_ids;
      ids?.forEach((id) => attachmentIdsInHistory.add(id));
    }
    const imageFileMap = attachmentIdsInHistory.size > 0
      ? await fetchImageFiles(supabase, [...attachmentIdsInHistory])
      : new Map();

    const claudeMessages: ClaudeMessage[] = [];
    for (const row of rows) {
      const role: "user" | "assistant" = row.role === "agent" ? "assistant" : "user";
      const ids = (row.metadata as { attachment_file_ids?: string[] } | null)?.attachment_file_ids;

      if (ids?.length) {
        const files = ids
          .map((id: string) => imageFileMap.get(id))
          .filter((f: unknown): f is NonNullable<typeof f> => !!f);
        const imageBlocks = await buildImageBlocks(supabase, files);
        const blocks: ClaudeContentBlock[] = [...imageBlocks];
        if (row.content?.trim()) blocks.push({ type: "text", text: row.content });
        claudeMessages.push({ role, content: blocks.length > 0 ? blocks : row.content });
      } else {
        claudeMessages.push({ role, content: row.content });
      }
    }

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
        replies_to_message_id: userMessage.id,
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
        supabase.from("embeddings").upsert({
          source_type: "message",
          source_id: agentMessage.id,
          content_preview: finalText.slice(0, 2000),
          embedding: toPgVector(vec),
        }, { onConflict: "source_type,source_id" })
      )
      .catch((e) => console.error("Failed to embed agent reply:", e));

    // 5. Silent knowledge extraction — never blocks the response.
    const backgroundWork = (async () => {
      try {
        const facts = await extractKnowledge(text);
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
            await supabase.from("embeddings").upsert({
              source_type: "extracted_knowledge",
              source_id: knowledgeRow.id,
              content_preview: fact.content.slice(0, 2000),
              embedding: toPgVector(vec),
            }, { onConflict: "source_type,source_id" });
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
