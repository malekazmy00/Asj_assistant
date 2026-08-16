// Resolves image attachment ids into Claude vision content blocks. Only
// `file_type = 'image'` is handled here — documents/audio/video have their
// own chunking + RAG pipeline (see process-file/index.ts) and are never
// sent inline to Claude.

import { encodeBase64 } from "jsr:@std/encoding@1/base64";
// deno-lint-ignore no-explicit-any
type SupabaseClient = any;
import type { ClaudeContentBlock } from "./anthropic.ts";

const ALLOWED_IMAGE_MIME_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/gif",
  "image/webp",
]);

export interface AttachmentFile {
  id: string;
  storage_path: string;
  mime_type: string | null;
}

/** Batch-fetches file rows (images only) for a set of ids. */
export async function fetchImageFiles(
  supabase: SupabaseClient,
  fileIds: string[],
): Promise<Map<string, AttachmentFile>> {
  const map = new Map<string, AttachmentFile>();
  if (fileIds.length === 0) return map;

  const { data } = await supabase
    .from("files")
    .select("id, storage_path, mime_type")
    .eq("file_type", "image")
    .in("id", fileIds);

  for (const row of data ?? []) map.set(row.id, row as AttachmentFile);
  return map;
}

/**
 * Downloads + base64-encodes the given image files into Claude content
 * blocks. A single bad/missing image is skipped (logged) rather than
 * failing the whole turn.
 */
export async function buildImageBlocks(
  supabase: SupabaseClient,
  files: AttachmentFile[],
): Promise<ClaudeContentBlock[]> {
  const blocks: ClaudeContentBlock[] = [];

  for (const file of files) {
    try {
      const mediaType = file.mime_type && ALLOWED_IMAGE_MIME_TYPES.has(file.mime_type)
        ? file.mime_type
        : "image/jpeg";

      const { data: blob, error } = await supabase.storage
        .from("uploads")
        .download(file.storage_path);
      if (error || !blob) {
        console.error(`Could not download image attachment ${file.id}:`, error);
        continue;
      }

      const bytes = new Uint8Array(await blob.arrayBuffer());
      blocks.push({
        type: "image",
        source: { type: "base64", media_type: mediaType, data: encodeBase64(bytes) },
      });
    } catch (e) {
      console.error(`Failed to process image attachment ${file.id}:`, e);
    }
  }

  return blocks;
}
