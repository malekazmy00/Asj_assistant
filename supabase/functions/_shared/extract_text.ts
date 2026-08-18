// Text extraction for uploaded documents. Plain text/markdown is handled
// directly; PDF and Word documents use small pure-JS npm packages (no
// native deps, so they run fine in the Edge Runtime). If a format ever
// fails to extract, the file is marked `failed` with the error message
// rather than silently producing nothing — see process-file/index.ts.

export async function extractText(
  bytes: Uint8Array,
  mimeType: string,
  filename: string,
  opts?: { maxPages?: number },
): Promise<string> {
  const ext = filename.split(".").pop()?.toLowerCase() ?? "";

  if (mimeType === "text/plain" || mimeType === "text/markdown" || ext === "txt" || ext === "md") {
    return new TextDecoder("utf-8").decode(bytes);
  }

  if (mimeType === "application/pdf" || ext === "pdf") {
    const { default: pdfParse } = await import("npm:pdf-parse@1.1.1");
    // pdf-parse's `max` caps how many pages it renders/parses (0 = all).
    // process-file's uploaded-document ingestion runs in the background
    // (EdgeRuntime.waitUntil) with no caller waiting on CPU budget, so it
    // leaves this unset and parses the whole thing. fetch_full_document
    // (chat/index.ts) is different: it runs synchronously mid-request,
    // stacked on top of whatever CPU the RAG/thinking/search work already
    // burned in the same invocation — a large scanned PDF (e.g. an FDA
    // 510(k) submission) there can trip Supabase's per-request CPU-time
    // limit and kill the entire chat turn with no answer at all (confirmed
    // live: "CPU Time exceeded" / WORKER_RESOURCE_LIMIT after fetching
    // accessdata.fda.gov/.../K113342.pdf). Callers on that path pass a cap.
    const result = await pdfParse(bytes, opts?.maxPages ? { max: opts.maxPages } : undefined);
    return result.text ?? "";
  }

  if (
    mimeType === "application/vnd.openxmlformats-officedocument.wordprocessingml.document" ||
    ext === "docx"
  ) {
    const mammoth = await import("npm:mammoth@1.8.0");
    const result = await mammoth.extractRawText({ buffer: bytes });
    return result.value ?? "";
  }

  if (mimeType === "application/msword" || ext === "doc") {
    throw new Error(
      "Legacy .doc format isn't supported for text extraction yet — please re-save as .docx or .pdf.",
    );
  }

  throw new Error(`Unsupported document type: ${mimeType || ext}`);
}
