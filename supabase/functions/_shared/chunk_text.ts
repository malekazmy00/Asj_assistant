// Simple paragraph-aware fixed-size chunking, good enough for v1 RAG.
const CHUNK_SIZE = 1200;
const CHUNK_OVERLAP = 150;

export function chunkText(text: string): string[] {
  const normalized = text.replace(/\r\n/g, "\n").trim();
  if (normalized.length <= CHUNK_SIZE) return [normalized];

  const paragraphs = normalized.split(/\n\s*\n/);
  const chunks: string[] = [];
  let current = "";

  for (const paragraph of paragraphs) {
    if ((current + "\n\n" + paragraph).length > CHUNK_SIZE && current.length > 0) {
      chunks.push(current.trim());
      // start next chunk with a small overlap for context continuity
      const overlap = current.slice(Math.max(0, current.length - CHUNK_OVERLAP));
      current = overlap + "\n\n" + paragraph;
    } else {
      current = current ? current + "\n\n" + paragraph : paragraph;
    }

    // A single paragraph longer than CHUNK_SIZE: hard-split it.
    while (current.length > CHUNK_SIZE * 1.5) {
      chunks.push(current.slice(0, CHUNK_SIZE).trim());
      current = current.slice(CHUNK_SIZE - CHUNK_OVERLAP);
    }
  }
  if (current.trim()) chunks.push(current.trim());

  return chunks.filter((c) => c.length > 0);
}
