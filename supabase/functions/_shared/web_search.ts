// Live web search via Tavily — this project's own client-side search
// tool, used as a stand-in for Gemini's native Google Search grounding
// (blocked on the current free-tier key — see gemini_chat.ts). Claude
// keeps using Anthropic's own server-side web_search tool as before; this
// tool is only offered to the Gemini path, and only when the user's
// live-search toggle is on (see chat/index.ts's buildTools()).
//
// NOT YET LIVE-VERIFIED — written against Tavily's documented REST shape,
// but per this project's established practice (Gemini's field casing has
// been wrong/ambiguous in docs before), this needs a real test against
// the live API with a real key before it's trusted. Do that before
// relying on this in production; update this comment once verified.

export interface WebSearchResult {
  title: string;
  url: string;
  snippet: string;
}

export async function searchWeb(query: string, maxResults = 5): Promise<WebSearchResult[]> {
  const apiKey = Deno.env.get("TAVILY_API_KEY");
  if (!apiKey) {
    throw new Error("TAVILY_API_KEY is not set");
  }

  const response = await fetch("https://api.tavily.com/search", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      query,
      search_depth: "basic",
      max_results: maxResults,
    }),
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Tavily API error ${response.status}: ${errText}`);
  }

  const data = await response.json();
  // deno-lint-ignore no-explicit-any
  const results = (data.results ?? []) as any[];
  return results.map((r) => ({
    title: r.title ?? r.url ?? "Untitled",
    url: r.url,
    snippet: (r.content ?? "").slice(0, 1000),
  }));
}
