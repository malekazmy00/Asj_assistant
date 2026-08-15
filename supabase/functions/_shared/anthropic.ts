// Minimal Claude Messages API client for the `chat` Edge Function.
//
// Uses extended thinking (stored separately from the final answer, see
// callClaude's return shape) and Anthropic's server-side web search tool —
// the search itself runs on Anthropic's side within the same request, so
// there is no client-side tool-execution loop to manage here.

const ANTHROPIC_VERSION = "2023-06-01";
const DEFAULT_MODEL = "claude-sonnet-5";
const DEFAULT_MAX_TOKENS = 8000;
const DEFAULT_THINKING_BUDGET = 4000;

export interface ClaudeMessage {
  role: "user" | "assistant";
  content: string;
}

export interface WebSearchCitation {
  title?: string;
  url?: string;
}

export interface ClaudeResult {
  thinkingText: string;
  finalText: string;
  webSearchUsed: boolean;
  citations: WebSearchCitation[];
  stopReason: string | null;
}

// deno-lint-ignore no-explicit-any
type ContentBlock = any;

export async function callClaude(opts: {
  systemPrompt: string;
  messages: ClaudeMessage[];
  model?: string;
  maxTokens?: number;
  thinkingBudget?: number;
  enableWebSearch?: boolean;
}): Promise<ClaudeResult> {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    throw new Error("ANTHROPIC_API_KEY is not set");
  }

  const body: Record<string, unknown> = {
    model: opts.model ?? DEFAULT_MODEL,
    max_tokens: opts.maxTokens ?? DEFAULT_MAX_TOKENS,
    thinking: {
      type: "enabled",
      budget_tokens: opts.thinkingBudget ?? DEFAULT_THINKING_BUDGET,
    },
    system: opts.systemPrompt,
    messages: opts.messages.map((m) => ({
      role: m.role,
      content: [{ type: "text", text: m.content }],
    })),
  };

  if (opts.enableWebSearch !== false) {
    body.tools = [
      { type: "web_search_20250305", name: "web_search", max_uses: 3 },
    ];
  }

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

  const thinkingText = blocks
    .filter((b) => b.type === "thinking")
    .map((b) => b.thinking as string)
    .join("\n\n");

  const finalText = blocks
    .filter((b) => b.type === "text")
    .map((b) => b.text as string)
    .join("\n\n");

  const webSearchUsed = blocks.some((b) => b.type === "server_tool_use" && b.name === "web_search");

  const citations: WebSearchCitation[] = blocks
    .filter((b) => b.type === "web_search_tool_result")
    .flatMap((b) => (Array.isArray(b.content) ? b.content : []))
    .filter((c: ContentBlock) => c.type === "web_search_result")
    .map((c: ContentBlock) => ({ title: c.title, url: c.url }));

  return {
    thinkingText,
    finalText,
    webSearchUsed,
    citations,
    stopReason: data.stop_reason ?? null,
  };
}
