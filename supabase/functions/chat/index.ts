// The `chat` Edge Function: the whole conversational loop.
//
// 1. Persist the user's message (idempotently — see below), including any
//    image attachments.
// 2. Embed it and pull relevant context via pgvector (RAG) — includes our
//    own cached official-tier web sources (web_source_chunks), not just
//    uploaded documents/recordings.
// 3. Call Claude with extended thinking, the web search tool, and two
//    client-side tools — fetch_full_document (read a source in full
//    rather than trust a search snippet) and flag_source_conflict (record
//    a contradiction between official-tier sources instead of silently
//    picking one) — see anthropic.ts for the tool-use loop this drives.
// 4. Persist the agent's reply, with thinking stored separately.
// 5. In the background (never blocks the response): embed the agent's
//    reply, silently extract knowledge from what the user said, and
//    write this turn's step timings to perf_logs.
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
import { callClaude, type ClaudeContentBlock, type ClaudeMessage, type ClaudeTool, type WebSearchCitation } from "../_shared/anthropic.ts";
import { callGemini } from "../_shared/gemini_chat.ts";
import { buildSystemPrompt } from "../_shared/system_prompt.ts";
import { embed, toPgVector } from "../_shared/embeddings.ts";
import { extractKnowledge } from "../_shared/extract_knowledge.ts";
import { buildImageBlocks, fetchImageFiles } from "../_shared/attachments.ts";
import { labelRagMatches } from "../_shared/rag_sources.ts";
import { chunkText } from "../_shared/chunk_text.ts";
import { extractPdfTextInBackground, fetchFullDocument } from "../_shared/fetch_document.ts";
import { searchWeb } from "../_shared/web_search.ts";

// deno-lint-ignore no-explicit-any
declare const EdgeRuntime: any;
// deno-lint-ignore no-explicit-any
type SupabaseClient = any;

const MAX_HISTORY_MESSAGES = 40;
const RAG_MATCH_COUNT = 8;
const RAG_MIN_SIMILARITY = 0.45;
// Tiers worth caching for future reuse and worth checking for conflicts.
// Marketplace/forum-tier content isn't trusted enough to be worth storing
// as if it were verified background knowledge.
const CACHEABLE_TIERS = new Set(["manual", "official", "distributor"]);
const CONFLICT_WORTHY_TIERS = new Set(["manual", "official"]);

// ---------------------------------------------------------------------
// Perf instrumentation (B7) — every major step's wall-clock time, written
// to perf_logs in the background so a slow turn can be diagnosed with
// real numbers instead of guessing which step was slow.
// ---------------------------------------------------------------------
interface PerfEntry {
  step: string;
  durationMs: number;
  // deno-lint-ignore no-explicit-any
  metadata?: Record<string, any>;
}

async function timeStep<T>(
  entries: PerfEntry[],
  step: string,
  // deno-lint-ignore no-explicit-any
  metadata: Record<string, any> | undefined,
  fn: () => Promise<T>,
): Promise<T> {
  const start = performance.now();
  try {
    const result = await fn();
    entries.push({ step, durationMs: Math.round(performance.now() - start), metadata });
    return result;
  } catch (e) {
    entries.push({ step, durationMs: Math.round(performance.now() - start), metadata: { ...metadata, error: true } });
    throw e;
  }
}

// ---------------------------------------------------------------------
// Web-source caching + conflict check (used by the fetch_full_document
// tool handler below). The conflict *check* is synchronous (Claude needs
// the answer this turn); the actual chunk+embed+store of the new content
// is deferred to background work the caller registers with
// EdgeRuntime.waitUntil — Claude only needs to read the text, not wait
// for us to finish filing it away for next time.
// ---------------------------------------------------------------------
async function checkForConflicts(
  supabase: SupabaseClient,
  newUrl: string,
  newTextSample: string,
): Promise<string> {
  try {
    const vec = await embed(newTextSample.slice(0, 2000));
    const { data: matches } = await supabase.rpc("match_embeddings", {
      query_embedding: toPgVector(vec),
      match_count: 5,
      exclude_source_type: null,
      exclude_source_id: null,
    });
    // deno-lint-ignore no-explicit-any
    const candidates = (matches ?? []).filter((m: any) => m.source_type === "web_source_chunk" && m.similarity >= 0.55);
    if (candidates.length === 0) return "";

    // deno-lint-ignore no-explicit-any
    const ids = candidates.map((c: any) => c.source_id);
    const { data: chunks } = await supabase
      .from("web_source_chunks")
      .select("id, source_url, source_title, trust_tier")
      .in("id", ids);

    // deno-lint-ignore no-explicit-any
    const related = (chunks ?? []).filter(
      // deno-lint-ignore no-explicit-any
      (c: any) => CONFLICT_WORTHY_TIERS.has(c.trust_tier) && c.source_url !== newUrl,
    );
    if (related.length === 0) return "";

    const lines = related
      // deno-lint-ignore no-explicit-any
      .map((c: any) => `  - [${c.trust_tier} tier] ${c.source_title || c.source_url} (${c.source_url})`)
      .join("\n");
    return `\n\n[We already have related official/manual-tier material on record from a different source:\n${lines}\nIf what you just read contradicts it on a compatibility/safety point, call flag_source_conflict rather than silently picking one.]`;
  } catch (e) {
    console.error("Conflict check failed (non-fatal):", e);
    return "";
  }
}

async function cacheWebSource(
  supabase: SupabaseClient,
  url: string,
  title: string | null,
  tier: string,
  text: string,
): Promise<void> {
  const chunks = chunkText(text);
  for (let i = 0; i < chunks.length; i++) {
    const { data: chunkRow, error } = await supabase
      .from("web_source_chunks")
      .upsert(
        { source_url: url, source_title: title, trust_tier: tier, chunk_index: i, content: chunks[i] },
        { onConflict: "source_url,chunk_index" },
      )
      .select()
      .single();
    if (error || !chunkRow) continue;

    try {
      const vec = await embed(chunks[i]);
      await supabase.from("embeddings").upsert({
        source_type: "web_source_chunk",
        source_id: chunkRow.id,
        content_preview: chunks[i].slice(0, 2000),
        embedding: toPgVector(vec),
      }, { onConflict: "source_type,source_id" });
    } catch (e) {
      console.error(`Failed to embed web_source_chunk for ${url}#${i}:`, e);
    }
  }
}

interface DeferredPdfExtraction {
  url: string;
  title: string | null;
  tier: string;
  bytes: Uint8Array;
}

function buildTools(
  supabase: SupabaseClient,
  perfEntries: PerfEntry[],
  backgroundWork: Promise<unknown>[],
  deferredPdfExtractions: DeferredPdfExtraction[],
  // Only present for the Gemini path — Claude keeps using Anthropic's own
  // server-side web_search tool. See web_search.ts's header: this is a
  // stand-in for Gemini's native Google Search grounding, which 429s
  // outright on the current free-tier key. `citationsOut` is written to
  // (not returned) so the caller can merge these into the same
  // `citations` list a provider's own native search would have populated.
  customSearch?: { citationsOut: WebSearchCitation[] },
): ClaudeTool[] {
  const tools: ClaudeTool[] = [
    {
      name: "fetch_full_document",
      description:
        "Fetch and read the FULL text of a web page or PDF you found via search, instead of relying on the short search snippet. Use this whenever a result looks like it might be an official service manual, manufacturer brochure, or spec sheet, and the question is compatibility/safety/spec-critical enough that skimming a snippet risks being wrong. Returns the full extracted text (PDF or HTML).",
      inputSchema: {
        type: "object",
        properties: {
          url: { type: "string", description: "The exact URL from the search result to fetch." },
          trust_tier: {
            type: "string",
            enum: ["manual", "official", "distributor", "marketplace"],
            description:
              "Your assessment of this source: 'manual' = an official service/repair manual; 'official' = the manufacturer's own site/brochure/spec sheet; 'distributor' = an authorized reseller/distributor's page; 'marketplace' = a general marketplace, forum, or upload site — lowest trust.",
          },
          source_title: {
            type: "string",
            description: "A short human-readable title, e.g. 'Siemens Somatom Definition Service Manual'.",
          },
        },
        required: ["url", "trust_tier"],
      },
      handler: async (input) => {
        const fetched = await timeStep(
          perfEntries, "fetch_full_document", { url: input.url }, () => fetchFullDocument(input.url),
        );

        // PDFs are never parsed inline — see fetch_document.ts for why
        // (a real ~1.3MB spec-sheet PDF tripped the platform's CPU-time
        // limit and killed the whole turn, confirmed live). Only *queue*
        // the bytes here — do NOT start extraction now. Confirmed live
        // (twice) that starting the async extraction here, even
        // unawaited/"fire-and-forget", still runs concurrently with the
        // rest of this same request/isolate and can itself trip the CPU
        // limit and kill the turn, unlike process-file's proven-safe
        // pattern of only starting such work from inside the final
        // EdgeRuntime.waitUntil block *after* the response is ready to
        // return. So: record the bytes now, actually extract+cache later,
        // down in that same final block — see main handler below.
        if (fetched.deferredPdfBytes) {
          if (CACHEABLE_TIERS.has(input.trust_tier)) {
            deferredPdfExtractions.push({
              url: input.url,
              title: input.source_title ?? null,
              tier: input.trust_tier,
              bytes: fetched.deferredPdfBytes,
            });
          }
          return (
            `[This is a PDF, and it's too resource-intensive to safely read in full right now — ` +
            `not something you should treat as read. It's been queued to be read and stored in the ` +
            `background, so a future question on this topic will be able to pull from it directly. ` +
            `For this answer, work from what you already have (the search result title/snippet, or ` +
            `other sources) and say plainly that you haven't read this particular PDF's full text.]`
          );
        }

        const { text, truncated } = fetched;

        let conflictNote = "";
        if (CONFLICT_WORTHY_TIERS.has(input.trust_tier)) {
          conflictNote = await timeStep(
            perfEntries, "conflict_check", { url: input.url },
            () => checkForConflicts(supabase, input.url, text),
          );
        }

        // Claude doesn't need to wait for us to finish filing this away —
        // only needs the text now. Caching happens after this handler
        // returns, registered with EdgeRuntime.waitUntil by the caller.
        if (CACHEABLE_TIERS.has(input.trust_tier)) {
          backgroundWork.push(
            timeStep(
              perfEntries, "cache_web_source", { url: input.url },
              () => cacheWebSource(supabase, input.url, input.source_title ?? null, input.trust_tier, text),
            ).catch((e) => console.error(`Failed to cache web source ${input.url}:`, e)),
          );
        }

        const prefix = truncated ? "[Note: this document was long; truncated to the first ~60,000 characters]\n\n" : "";
        return `${prefix}${text}${conflictNote}`;
      },
    },
    {
      name: "flag_source_conflict",
      description:
        "Call this when a source you just read directly contradicts something already found or stored from a previous conversation, on a compatibility/safety-relevant point, and both sides are at least official-tier (not a forum post). This does NOT resolve the conflict — it just records it for review. Say so plainly in your answer too instead of silently picking one.",
      inputSchema: {
        type: "object",
        properties: {
          description: { type: "string", description: "Plainly describe the conflict: what the two sources say and why they disagree." },
          source_url_a: { type: "string" },
          source_url_b: { type: "string" },
        },
        required: ["description"],
      },
      handler: async (input) => {
        const urls = [input.source_url_a, input.source_url_b].filter(Boolean);
        let existingChunkId: string | null = null;
        let newChunkId: string | null = null;
        if (urls.length > 0) {
          const { data: found } = await supabase
            .from("web_source_chunks")
            .select("id, source_url")
            .in("source_url", urls)
            .limit(2);
          if (found && found.length > 0) existingChunkId = found[0].id;
          if (found && found.length > 1) newChunkId = found[1].id;
        }
        await supabase.from("source_conflicts").insert({
          existing_chunk_id: existingChunkId,
          new_chunk_id: newChunkId,
          description: input.description,
        });
        return "Noted for review.";
      },
    },
  ];

  if (customSearch) {
    tools.push({
      name: "web_search",
      description:
        "Search the web live for a topic. Returns a short list of results (title, url, snippet). Use this to find current information or to discover a URL worth reading in full via fetch_full_document — don't answer compatibility/safety-critical questions from the snippet alone.",
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string", description: "The search query." },
        },
        required: ["query"],
      },
      handler: async (input) => {
        const results = await timeStep(
          perfEntries, "web_search", { query: input.query }, () => searchWeb(input.query),
        );
        for (const r of results) {
          customSearch.citationsOut.push({ title: r.title, url: r.url });
        }
        if (results.length === 0) return "No results found.";
        return results.map((r) => `- ${r.title} (${r.url}): ${r.snippet}`).join("\n");
      },
    });
  }

  return tools;
}

Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  const perfEntries: PerfEntry[] = [];
  const requestStart = performance.now();

  try {
    const { conversation_id, content, client_message_id, attachment_file_ids, enable_search } = await req.json();
    const attachmentIds: string[] = Array.isArray(attachment_file_ids) ? attachment_file_ids : [];
    const text: string = typeof content === "string" ? content : "";
    // Defaults on — the Flutter toggle sends this explicitly either way,
    // but treat a missing/malformed value as "search enabled" rather than
    // silently going quiet, since that's the existing (pre-toggle) behavior.
    const enableSearch: boolean = enable_search !== false;

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

      userMessage = await timeStep(perfEntries, "user_message_insert", undefined, async () => {
        const { data: inserted, error: userInsertError } = await supabase
          .from("messages")
          .insert(insertPayload)
          .select()
          .single();
        if (userInsertError) throw userInsertError;
        return inserted;
      });
    }

    // 2. Embed it; retrieve relevant context — including our own cached
    // official-tier web sources, not just uploaded documents/recordings.
    // (Skip for image-only messages with no text.) Upsert since a resumed
    // retry may have already embedded this message in a prior attempt.
    let ragContext = "";
    if (text.trim()) {
      try {
        await timeStep(perfEntries, "rag_retrieval", undefined, async () => {
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
            const lines = (await labelRagMatches(supabase, relevant)).join("\n");
            ragContext =
              `\n# Things you already know that might be relevant right now\n` +
              `(Use this naturally if it fits the moment — don't recite it verbatim, and don't force a connection that isn't there. ` +
              `Lines tagged with a tier are cite-able by name at that tier; untagged lines are your own recall — don't invent a source for those.)\n${lines}\n`;
          }
        });
      } catch (e) {
        console.error("RAG retrieval failed, continuing without context:", e);
      }
    }

    // 3. Build history — reconstructing image attachments for any message
    // within the window that carried them, not just this turn's — and
    // call Claude.
    const { historyRows } = await timeStep(perfEntries, "history_build", undefined, async () => {
      const { data, error: historyError } = await supabase
        .from("messages")
        .select("role, content, metadata")
        .eq("conversation_id", conversation_id)
        .order("created_at", { ascending: true })
        .limit(MAX_HISTORY_MESSAGES);
      if (historyError) throw historyError;
      return { historyRows: data ?? [] };
    });

    const rows = historyRows;

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

    const cacheBackgroundWork: Promise<unknown>[] = [];
    const deferredPdfExtractions: DeferredPdfExtraction[] = [];
    const systemPrompt = buildSystemPrompt(ragContext);

    // Provider toggle (LLM_PROVIDER=claude|gemini, default claude) — for
    // trying Gemini as an A/B comparison without ripping out the working
    // Claude path. Both share the exact same ClaudeMessage/ClaudeTool/
    // ClaudeResult shapes (see gemini_chat.ts), so nothing else here needs
    // to branch. Known live constraint on the current Gemini key: no
    // Pro-tier model access (0 quota) and Google Search grounding 429s
    // outright — see gemini_chat.ts's header comment for what was
    // actually verified against the live API before wiring this in.
    const llmProvider = (Deno.env.get("LLM_PROVIDER") ?? "claude").toLowerCase();

    // Custom web_search tool is only offered to Gemini (Claude keeps its
    // own native search) and only when the client's live-search toggle
    // (see chat_composer.dart) is on. Its results feed citationsOut,
    // merged into the reply's citations below alongside whatever the
    // provider's own native search/grounding found.
    const customSearchCitations: WebSearchCitation[] = [];
    const tools = buildTools(
      supabase, perfEntries, cacheBackgroundWork, deferredPdfExtractions,
      llmProvider === "gemini" && enableSearch ? { citationsOut: customSearchCitations } : undefined,
    );

    const result = await timeStep(perfEntries, "llm_call", { provider: llmProvider }, () =>
      llmProvider === "gemini"
        ? callGemini({ systemPrompt, messages: claudeMessages, tools })
        : callClaude({ systemPrompt, messages: claudeMessages, tools, enableWebSearch: enableSearch }));

    const finalText = result.finalText.trim() ||
      "Sorry, I didn't catch that — could you say it again?";
    const allCitations = [...result.citations, ...customSearchCitations];

    // 4. Persist the agent's reply, thinking stored separately.
    const agentMessage = await timeStep(perfEntries, "agent_message_insert", undefined, async () => {
      const { data, error: agentInsertError } = await supabase
        .from("messages")
        .insert({
          conversation_id,
          role: "agent",
          content: finalText,
          thinking_content: result.thinkingText || null,
          replies_to_message_id: userMessage.id,
          metadata: {
            llm_provider: llmProvider,
            search_enabled: enableSearch,
            web_search_used: result.webSearchUsed || customSearchCitations.length > 0,
            citations: allCitations,
            tool_calls: result.toolCalls.map((t) => ({ name: t.name, input: t.input, is_error: t.isError })),
          },
        })
        .select()
        .single();
      if (agentInsertError) throw agentInsertError;
      return data;
    });

    // 5. Everything from here on is genuinely after-the-response work —
    // embedding the reply, silent knowledge extraction, finishing the
    // web-source caching kicked off during tool calls above, and writing
    // this turn's perf numbers — none of it needs to block the client
    // from seeing the answer, which is already fully generated and saved.
    const backgroundWork = (async () => {
      await Promise.allSettled([
        embed(finalText)
          .then((vec) =>
            supabase.from("embeddings").upsert({
              source_type: "message",
              source_id: agentMessage.id,
              content_preview: finalText.slice(0, 2000),
              embedding: toPgVector(vec),
            }, { onConflict: "source_type,source_id" })
          )
          .catch((e) => console.error("Failed to embed agent reply:", e)),

        (async () => {
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
        })(),

        ...cacheBackgroundWork,
      ]);

      perfEntries.push({ step: "total", durationMs: Math.round(performance.now() - requestStart) });
      try {
        await supabase.from("perf_logs").insert(
          perfEntries.map((e) => ({
            conversation_id,
            message_id: agentMessage.id,
            step: e.step,
            duration_ms: e.durationMs,
            metadata: e.metadata ?? {},
          })),
        );
      } catch (e) {
        console.error("Failed to write perf_logs:", e);
      }
    })();

    // Deferred PDF extraction is chained to start only *after*
    // backgroundWork above has fully settled — deliberately, not just for
    // tidiness. First attempt registered it as a separate, independent
    // waitUntil running concurrently with backgroundWork, on the theory
    // that an unrelated isolate kill couldn't touch a promise that wasn't
    // part of the same Promise.allSettled. Confirmed live that this
    // didn't work: perf_logs still went unwritten. Root cause is simpler
    // and more fundamental — Deno/V8 is single-threaded, and pdf-parse's
    // extraction is CPU-bound synchronous-ish work that hogs the one
    // thread once it starts, starving even *unrelated* pending promises
    // (the reply-embedding fetch, the perf_logs insert) of any chance to
    // run their continuations before the isolate gets killed for CPU
    // overuse. "Separate waitUntil" ≠ "separate thread." Chaining with
    // .then() guarantees backgroundWork's network calls and DB writes
    // actually run and complete before this riskier, best-effort PDF work
    // ever touches the CPU — not a race, an ordering guarantee.
    const pdfBackgroundWork = backgroundWork.then(() =>
      Promise.allSettled(
        deferredPdfExtractions.map((d) =>
          (async () => {
            const pdfText = await extractPdfTextInBackground(d.bytes, d.url);
            await cacheWebSource(supabase, d.url, d.title, d.tier, pdfText);
          })().catch((e) => console.error(`Failed to background-extract/cache PDF ${d.url}:`, e))
        ),
      )
    );

    if (typeof EdgeRuntime !== "undefined") {
      EdgeRuntime.waitUntil(backgroundWork);
      if (deferredPdfExtractions.length > 0) EdgeRuntime.waitUntil(pdfBackgroundWork);
    } else {
      // Local `supabase functions serve` doesn't have EdgeRuntime; just await.
      await backgroundWork;
      await pdfBackgroundWork;
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
