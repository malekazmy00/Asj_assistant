// Embeddings via Supabase Edge Runtime's built-in `gte-small` model
// (384 dimensions). No external API key required — this is what
// migrations/0001_init.sql's `embeddings.embedding vector(384)` column
// assumes.

// deno-lint-ignore no-explicit-any
declare const Supabase: any;

let session: unknown = null;

function getSession() {
  if (!session) {
    session = new Supabase.ai.Session("gte-small");
  }
  return session;
}

export async function embed(text: string): Promise<number[]> {
  const model = getSession();
  const output = await (model as {
    run: (
      text: string,
      opts: { mean_pool: boolean; normalize: boolean },
    ) => Promise<number[]>;
  }).run(text, { mean_pool: true, normalize: true });
  return Array.from(output);
}

export function toPgVector(embedding: number[]): string {
  return `[${embedding.join(",")}]`;
}
