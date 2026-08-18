// Resolves document_chunk / transcript_segment / web_source_chunk RAG
// matches to a citable name (+ tag/trust tier) so the agent can cite them
// naturally — see "Citing what you know" in system_prompt.ts. Matches from
// messages or extracted_knowledge are left unlabeled; that's
// conversational recall ("you mentioned before"), not a source citation,
// and is already handled by the prompt's bridging guidance.

// deno-lint-ignore no-explicit-any
type SupabaseClient = any;

export interface RagMatch {
  source_type: string;
  source_id: string;
  content_preview: string;
  similarity: number;
}

interface FileInfo {
  filename: string;
  tag: string | null;
}

async function fileInfoBySourceId(
  supabase: SupabaseClient,
  sourceTable: "document_chunks" | "transcript_segments",
  sourceIds: string[],
): Promise<Map<string, FileInfo>> {
  const result = new Map<string, FileInfo>();
  if (sourceIds.length === 0) return result;

  const { data: sources } = await supabase
    .from(sourceTable)
    .select("id, file_id")
    .in("id", sourceIds);

  // deno-lint-ignore no-explicit-any
  const fileIds = [...new Set((sources ?? []).map((s: any) => s.file_id))];
  if (fileIds.length === 0) return result;

  const { data: files } = await supabase
    .from("files")
    .select("id, filename, tag")
    .in("id", fileIds);
  // deno-lint-ignore no-explicit-any
  const fileById = new Map((files ?? []).map((f: any) => [f.id, f]));

  // deno-lint-ignore no-explicit-any
  for (const s of sources ?? []) {
    const f = fileById.get(s.file_id);
    if (f) result.set(s.id, { filename: f.filename, tag: f.tag ?? null });
  }
  return result;
}

interface WebSourceInfo {
  sourceUrl: string;
  sourceTitle: string | null;
  trustTier: string;
}

async function webSourceInfoBySourceId(
  supabase: SupabaseClient,
  sourceIds: string[],
): Promise<Map<string, WebSourceInfo>> {
  const result = new Map<string, WebSourceInfo>();
  if (sourceIds.length === 0) return result;

  const { data } = await supabase
    .from("web_source_chunks")
    .select("id, source_url, source_title, trust_tier")
    .in("id", sourceIds);

  // deno-lint-ignore no-explicit-any
  for (const row of data ?? []) {
    result.set(row.id, { sourceUrl: row.source_url, sourceTitle: row.source_title, trustTier: row.trust_tier });
  }
  return result;
}

/** Formats RAG matches into citable context lines, tagging any that trace
 * back to an uploaded document, a recording, or a previously-fetched web
 * source with its name/tier — this is what lets the agent say "from that
 * Siemens page I read last time" instead of treating cached web content
 * like its own general knowledge (see "When you already have this
 * cached" in system_prompt.ts). */
export async function labelRagMatches(
  supabase: SupabaseClient,
  matches: RagMatch[],
): Promise<string[]> {
  const chunkIds = matches.filter((m) => m.source_type === "document_chunk").map((m) => m.source_id);
  const segmentIds = matches.filter((m) => m.source_type === "transcript_segment").map((m) => m.source_id);
  const webSourceIds = matches.filter((m) => m.source_type === "web_source_chunk").map((m) => m.source_id);

  const [fileByChunk, fileBySegment, webSourceById] = await Promise.all([
    fileInfoBySourceId(supabase, "document_chunks", chunkIds),
    fileInfoBySourceId(supabase, "transcript_segments", segmentIds),
    webSourceInfoBySourceId(supabase, webSourceIds),
  ]);

  return matches.map((m) => {
    if (m.source_type === "document_chunk" && fileByChunk.has(m.source_id)) {
      const { filename, tag } = fileByChunk.get(m.source_id)!;
      return `- [manual tier, from the document "${filename}"${tag ? ` (tag: ${tag})` : ""}]: ${m.content_preview}`;
    }
    if (m.source_type === "transcript_segment" && fileBySegment.has(m.source_id)) {
      const { filename } = fileBySegment.get(m.source_id)!;
      return `- [from the recording "${filename}"]: ${m.content_preview}`;
    }
    if (m.source_type === "web_source_chunk" && webSourceById.has(m.source_id)) {
      const { sourceUrl, sourceTitle, trustTier } = webSourceById.get(m.source_id)!;
      const name = sourceTitle || sourceUrl;
      return `- [${trustTier} tier, previously fetched from "${name}" (${sourceUrl}) — cite as something you already read, not something you just checked]: ${m.content_preview}`;
    }
    return `- ${m.content_preview}`;
  });
}
