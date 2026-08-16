// Resolves document_chunk / transcript_segment RAG matches to their source
// file's name (and tag, if any) so the agent can cite them naturally — see
// "Citing what you know" in system_prompt.ts. Matches from messages or
// extracted_knowledge are left unlabeled; that's conversational recall
// ("you mentioned before"), not a document citation, and is already
// handled by the prompt's bridging guidance.

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

/** Formats RAG matches into citable context lines, tagging any that trace
 * back to an uploaded document or recording with its filename. */
export async function labelRagMatches(
  supabase: SupabaseClient,
  matches: RagMatch[],
): Promise<string[]> {
  const chunkIds = matches.filter((m) => m.source_type === "document_chunk").map((m) => m.source_id);
  const segmentIds = matches.filter((m) => m.source_type === "transcript_segment").map((m) => m.source_id);

  const [fileByChunk, fileBySegment] = await Promise.all([
    fileInfoBySourceId(supabase, "document_chunks", chunkIds),
    fileInfoBySourceId(supabase, "transcript_segments", segmentIds),
  ]);

  return matches.map((m) => {
    if (m.source_type === "document_chunk" && fileByChunk.has(m.source_id)) {
      const { filename, tag } = fileByChunk.get(m.source_id)!;
      return `- [from the document "${filename}"${tag ? ` (tag: ${tag})` : ""}]: ${m.content_preview}`;
    }
    if (m.source_type === "transcript_segment" && fileBySegment.has(m.source_id)) {
      const { filename } = fileBySegment.get(m.source_id)!;
      return `- [from the recording "${filename}"]: ${m.content_preview}`;
    }
    return `- ${m.content_preview}`;
  });
}
