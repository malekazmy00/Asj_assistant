// Minimal Claude Messages API client for the `chat` Edge Function.
//
// Uses extended thinking (stored separately from the final answer, see
// callClaude's return shape), Anthropic's server-side web search tool
// (search itself runs on Anthropic's side, no loop needed for that one),
// and — new — a small client-side tool-use loop for our own tools
// (fetch_full_document, flag_source_conflict; see chat/index.ts) where WE
// have to execute the tool and hand the result back before Claude can
// continue.

const ANTHROPIC_VERSION = "2023-06-01";
const DEFAULT_MODEL = "claude-sonnet-5";
const DEFAULT_MAX_TOKENS = 8000;
// claude-sonnet-5 uses adaptive thinking (effort-based), not the older
// manual "enabled"/budget_tokens shape — that shape 400s on this model.
const DEFAULT_EFFORT = "high";
// Safety cap on the client-tool loop — a real turn needs at most a
// couple of full-document reads; this just guards against a runaway loop
// if the model keeps calling tools instead of ever finalizing.
const MAX_TOOL_TURNS = 6;

export interface ClaudeImageBlock {
  type: "image";
  source: { type: "base64"; media_type: string; data: string };
}

export interface ClaudeTextBlock {
  type: "text";
  text: string;
}

export type ClaudeContentBlock = ClaudeTextBlock | ClaudeImageBlock;

export interface ClaudeMessage {
  role: "user" | "assistant";
  // A plain string is the common case (wrapped in a single text block
  // below); pass an array directly for messages carrying images.
  content: string | ClaudeContentBlock[];
}

export interface WebSearchCitation {
  title?: string;
  url?: string;
}

/** One of our own tools that Claude can call mid-turn. `handler` does the
 * actual work (fetching a URL, writing a conflict record, ...) and
 * returns the plain-text tool_result content to hand back to Claude. */
export interface ClaudeTool {
  name: string;
  description: string;
  // deno-lint-ignore no-explicit-any
  inputSchema: Record<string, any>;
  // deno-lint-ignore no-explicit-any
  handler: (input: any) => Promise<string>;
}

/** A record of one client-tool call this turn, for the caller to act on
 * afterward (e.g. chat/index.ts decides whether a successful
 * fetch_full_document call is worth persisting to web_source_chunks). */
export interface ClaudeToolCall {
  name: string;
  // deno-lint-ignore no-explicit-any
  input: any;
  result: string;
  isError: boolean;
}

export interface ClaudeResult {
  thinkingText: string;
  finalText: string;
  webSearchUsed: boolean;
  citations: WebSearchCitation[];
  toolCalls: ClaudeToolCall[];
  stopReason: string | null;
}

// deno-lint-ignore no-explicit-any
type ContentBlock = any;

export async function callClaude(opts: {
  systemPrompt: string;
  messages: ClaudeMessage[];
  model?: string;
  maxTokens?: number;
  effort?: "low" | "medium" | "high";
  enableWebSearch?: boolean;
  tools?: ClaudeTool[];
}): Promise<ClaudeResult> {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    throw new Error("ANTHROPIC_API_KEY is not set");
  }

  const clientTools = opts.tools ?? [];
  const toolsByName = new Map(clientTools.map((t) => [t.name, t]));

  // deno-lint-ignore no-explicit-any
  const conversation: any[] = opts.messages.map((m) => ({
    role: m.role,
    content: typeof m.content === "string" ? [{ type: "text", text: m.content }] : m.content,
  }));

  const thinkingParts: string[] = [];
  const textParts: string[] = [];
  let webSearchUsed = false;
  const citations: WebSearchCitation[] = [];
  const toolCalls: ClaudeToolCall[] = [];
  let stopReason: string | null = null;

  for (let turn = 0; turn < MAX_TOOL_TURNS; turn++) {
    const body: Record<string, unknown> = {
      model: opts.model ?? DEFAULT_MODEL,
      max_tokens: opts.maxTokens ?? DEFAULT_MAX_TOKENS,
      // display: "summarized" — claude-sonnet-5 defaults to "omitted" (thinking
      // happens and is billed either way, but the text comes back empty). The
      // brief requires persisting real thinking content, so opt into it.
      thinking: { type: "adaptive", display: "summarized" },
      output_config: { effort: opts.effort ?? DEFAULT_EFFORT },
      system: opts.systemPrompt,
      messages: conversation,
    };

    const tools: Record<string, unknown>[] = [];
    if (opts.enableWebSearch !== false) {
      tools.push({ type: "web_search_20250305", name: "web_search", max_uses: 3 });
    }
    for (const t of clientTools) {
      tools.push({ name: t.name, description: t.description, input_schema: t.inputSchema });
    }
    if (tools.length > 0) body.tools = tools;

    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": ANTHROPIC_VERSION,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`Claude API error ${response.status}: ${errText}`);
    }

    const data = await response.json();
    const blocks: ContentBlock[] = data.content ?? [];
    stopReason = data.stop_reason ?? null;

    thinkingParts.push(
      ...blocks.filter((b) => b.type === "thinking").map((b) => b.thinking as string),
    );
    textParts.push(...blocks.filter((b) => b.type === "text").map((b) => b.text as string));

    if (blocks.some((b) => b.type === "server_tool_use" && b.name === "web_search")) {
      webSearchUsed = true;
    }
    citations.push(
      ...blocks
        .filter((b) => b.type === "web_search_tool_result")
        .flatMap((b) => (Array.isArray(b.content) ? b.content : []))
        .filter((c: ContentBlock) => c.type === "web_search_result")
        .map((c: ContentBlock) => ({ title: c.title, url: c.url })),
    );

    const clientToolUses = blocks.filter(
      (b) => b.type === "tool_use" && toolsByName.has(b.name),
    );

    if (stopReason !== "tool_use" || clientToolUses.length === 0) {
      break; // final answer (or a stop we don't have a handler for) — done
    }

    // Claude's turn (all its content blocks, including tool_use) goes back
    // into the conversation, then our tool results as the next user turn —
    // this is the standard Anthropic tool-use loop shape.
    conversation.push({ role: "assistant", content: blocks });

    const toolResultBlocks = await Promise.all(
      clientToolUses.map(async (block: ContentBlock) => {
        const tool = toolsByName.get(block.name)!;
        let resultText: string;
        let isError = false;
        try {
          resultText = await tool.handler(block.input);
        } catch (e) {
          isError = true;
          resultText = `Error: ${(e as Error).message ?? String(e)}`;
        }
        toolCalls.push({ name: block.name, input: block.input, result: resultText, isError });
        return {
          type: "tool_result",
          tool_use_id: block.id,
          content: resultText,
          is_error: isError,
        };
      }),
    );
    conversation.push({ role: "user", content: toolResultBlocks });
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
