// Silent, best-effort extraction of atomic factual claims from the user's
// own messages (his business/technical expertise — the whole point of this
// app). Runs after the chat reply is already on its way back to the client
// (see chat/index.ts's use of EdgeRuntime.waitUntil), so it never adds
// latency to the conversation and never surfaces anything in the chat UI.

const ANTHROPIC_VERSION = "2023-06-01";
const MODEL = "claude-sonnet-5";

export interface ExtractedFact {
  content: string;
  topic: string | null;
}

const EXTRACTION_SYSTEM_PROMPT =
  `You extract atomic, standalone factual claims about the medical imaging equipment trade (maintenance, parts, pricing, suppliers, clients, procedures, equipment behavior, etc.) from a single chat message written by a business owner. Only extract things stated as fact about the business/trade/equipment — not questions, not greetings, not opinions phrased as pure preference, not anything you're not confident was actually asserted. Each fact should stand alone and make sense without the original message. If nothing worth capturing is present, return an empty list. Be conservative: when in doubt, leave it out.`;

export async function extractKnowledge(userText: string): Promise<ExtractedFact[]> {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return [];
  // Not worth a model call for very short/likely-non-substantive messages.
  if (userText.trim().length < 12) return [];

  const body = {
    model: MODEL,
    max_tokens: 1024,
    system: EXTRACTION_SYSTEM_PROMPT,
    messages: [{ role: "user", content: [{ type: "text", text: userText }] }],
    tools: [
      {
        name: "record_facts",
        description: "Record the atomic facts extracted from the message.",
        input_schema: {
          type: "object",
          properties: {
            facts: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  content: { type: "string", description: "The standalone fact." },
                  topic: {
                    type: "string",
                    description: "Short free-text category, e.g. equipment/brand/subject.",
                  },
                },
                required: ["content"],
              },
            },
          },
          required: ["facts"],
        },
      },
    ],
    tool_choice: { type: "tool", name: "record_facts" },
  };

  try {
    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": ANTHROPIC_VERSION,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });
    if (!response.ok) return [];

    const data = await response.json();
    // deno-lint-ignore no-explicit-any
    const toolBlock = (data.content ?? []).find((b: any) => b.type === "tool_use");
    if (!toolBlock) return [];

    const facts = toolBlock.input?.facts ?? [];
    return facts
      // deno-lint-ignore no-explicit-any
      .filter((f: any) => typeof f.content === "string" && f.content.trim().length > 0)
      // deno-lint-ignore no-explicit-any
      .map((f: any) => ({ content: f.content.trim(), topic: f.topic?.trim() || null }));
  } catch {
    // Extraction is best-effort; never let it break the chat flow.
    return [];
  }
}
