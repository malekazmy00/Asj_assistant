// Gemini equivalent of anthropic.ts's callClaude() — same input/output
// shape (reuses ClaudeMessage/ClaudeTool/ClaudeResult types directly) so
// chat/index.ts can switch providers via one env var (LLM_PROVIDER)
// without touching buildTools(), the RAG context, or anything else.
//
// Every protocol detail below was verified against the live API with the
// actual key in use, not assumed from docs (this project's established
// practice — Gemini's docs have been wrong/ambiguous before):
//
// - Model access: this key's free tier returns 0 quota for Pro-tier
//   models (gemini-3.1-pro-preview etc, confirmed via the API's own
//   RESOURCE_EXHAUSTED/limit:0 error) — only Flash-tier models work.
//   Defaults to gemini-3.6-flash, the same model already proven live for
//   voice transcription in this project.
// - Google Search grounding (`tools: [{googleSearch:{}}]`) 429s outright
//   on this key even on a Flash model with zero prior calls — not a rate
//   limit from testing, a hard "not available on this tier" wall. Off by
//   default (GEMINI_CHAT_ENABLE_SEARCH=false); flip the env var once a
//   billing-enabled key is in use. Left OFF, this build has no live
//   Gemini equivalent of the app's web-search sourcing feature.
// - Function-calling `parameters` accepts lowercase JSON Schema types
//   ("object"/"string", same as our existing ClaudeTool.inputSchema) —
//   no schema conversion needed, verified against both upper/lowercase.
// - Gemini 3.x requires the exact `thoughtSignature` from a prior model
//   turn's parts to be replayed verbatim when that turn re-enters the
//   conversation (confirmed: omitting it 400s with "missing a
//   thought_signature"). Solved the same way anthropic.ts's loop already
//   handles Claude's tool blocks: push the *exact* parts array the API
//   returned back into `contents`, never a reconstructed one.

import type { ClaudeMessage, ClaudeResult, ClaudeTool, ClaudeToolCall, WebSearchCitation } from "./anthropic.ts";

const GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta/models";
const DEFAULT_MODEL = "gemini-3.6-flash";
const MAX_TOOL_TURNS = 6;

// deno-lint-ignore no-explicit-any
type GeminiPart = any;

export async function callGemini(opts: {
  systemPrompt: string;
  messages: ClaudeMessage[];
  model?: string;
  tools?: ClaudeTool[];
}): Promise<ClaudeResult> {
  const apiKey = Deno.env.get("GEMINI_CHAT_API_KEY");
  if (!apiKey) {
    throw new Error("GEMINI_CHAT_API_KEY is not set");
  }
  const model = opts.model ?? Deno.env.get("GEMINI_CHAT_MODEL") ?? DEFAULT_MODEL;
  const enableSearch = (Deno.env.get("GEMINI_CHAT_ENABLE_SEARCH") ?? "false").toLowerCase() === "true";

  const clientTools = opts.tools ?? [];
  const toolsByName = new Map(clientTools.map((t) => [t.name, t]));

  // deno-lint-ignore no-explicit-any
  const contents: any[] = opts.messages.map((m) => ({
    role: m.role === "assistant" ? "model" : "user",
    parts: typeof m.content === "string"
      ? [{ text: m.content }]
      : m.content.map((b) =>
        b.type === "image"
          ? { inlineData: { mimeType: b.source.media_type, data: b.source.data } }
          : { text: b.text }
      ),
  }));

  const thinkingParts: string[] = [];
  const textParts: string[] = [];
  let webSearchUsed = false;
  const citations: WebSearchCitation[] = [];
  const toolCalls: ClaudeToolCall[] = [];
  let stopReason: string | null = null;

  for (let turn = 0; turn < MAX_TOOL_TURNS; turn++) {
    const tools: Record<string, unknown>[] = [];
    if (enableSearch) tools.push({ googleSearch: {} });
    if (clientTools.length > 0) {
      tools.push({
        functionDeclarations: clientTools.map((t) => ({
          name: t.name,
          description: t.description,
          parameters: t.inputSchema,
        })),
      });
    }

    // includeThoughts (visible reasoning text) is requested only on turn
    // 0, not every tool-selection turn. Real crash traced to this: a turn
    // that follows a web_search + fetch_full_document round (contents
    // already carrying tens of KB of fetched page text) hit "CPU Time
    // exceeded" — confirmed live via function_logs, same failure mode as
    // the earlier PDF-extraction issue (this project's per-request CPU
    // budget is cumulative across the whole call chain). includeThoughts
    // adds a full visible reasoning trace to EVERY turn's response, not
    // just the final one — on a tool-heavy turn that means paying full
    // thinking-generation + JSON-parse cost for turns whose only job is
    // "which tool to call next," stacking on top of whatever the rest of
    // the request already spent, right where contents is already
    // largest. We can't know in advance which turn will be the final
    // (non-tool-calling) one, so this trades losing the visible
    // reasoning trace on tool-heavy turns for not crashing them — most
    // ordinary conversational turns never call a tool at all and keep
    // full thinking, since turn 0 already is their final turn.
    // thoughtSignature (required for the multi-turn tool protocol — see
    // module comment) is present regardless of includeThoughts, confirmed
    // live, so this doesn't break the tool loop, only trims what we ask
    // the model to narrate along the way.
    const body: Record<string, unknown> = {
      systemInstruction: { parts: [{ text: opts.systemPrompt }] },
      contents,
      generationConfig: { thinkingConfig: { includeThoughts: turn === 0 } },
    };
    if (tools.length > 0) body.tools = tools;

    const turnStart = performance.now();
    const response = await fetch(`${GEMINI_API_BASE}/${model}:generateContent?key=${apiKey}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const fetchMs = Math.round(performance.now() - turnStart);

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`Gemini API error ${response.status}: ${errText}`);
    }

    const parseStart = performance.now();
    const data = await response.json();
    const parseMs = Math.round(performance.now() - parseStart);
    const candidate = data.candidates?.[0];
    const parts: GeminiPart[] = candidate?.content?.parts ?? [];
    stopReason = candidate?.finishReason ?? null;
    console.log(
      `gemini turn ${turn}: fetch=${fetchMs}ms parse=${parseMs}ms parts=${parts.length} ` +
        `stopReason=${stopReason} contentsSoFar=${JSON.stringify(contents).length}chars`,
    );

    thinkingParts.push(...parts.filter((p) => p.thought && p.text).map((p) => p.text as string));
    textParts.push(...parts.filter((p) => p.text && !p.thought).map((p) => p.text as string));

    const grounding = candidate?.groundingMetadata;
    if (grounding) {
      webSearchUsed = true;
      for (const chunk of grounding.groundingChunks ?? []) {
        if (chunk.web) citations.push({ title: chunk.web.title, url: chunk.web.uri });
      }
    }

    const functionCallParts = parts.filter((p) => p.functionCall && toolsByName.has(p.functionCall.name));
    if (functionCallParts.length === 0) {
      break; // final answer (or a stop we don't have a handler for) — done
    }

    // Push the model's turn back EXACTLY as returned (all parts, thought
    // parts and thoughtSignature included) — see module comment on why
    // reconstructing this turn from scratch 400s on Gemini 3.x.
    contents.push({ role: "model", parts });

    const responseParts = await Promise.all(
      functionCallParts.map(async (p: GeminiPart) => {
        const tool = toolsByName.get(p.functionCall.name)!;
        let resultText: string;
        let isError = false;
        try {
          resultText = await tool.handler(p.functionCall.args);
        } catch (e) {
          isError = true;
          resultText = `Error: ${(e as Error).message ?? String(e)}`;
        }
        toolCalls.push({ name: p.functionCall.name, input: p.functionCall.args, result: resultText, isError });
        return {
          functionResponse: {
            name: p.functionCall.name,
            id: p.functionCall.id,
            response: { result: resultText },
          },
        };
      }),
    );
    contents.push({ role: "user", parts: responseParts });
  }

  return {
    thinkingText: thinkingParts.join("\n\n"),
    finalText: textParts.join("\n\n"),
    webSearchUsed,
    citations,
    toolCalls,
    stopReason,
  };
}
