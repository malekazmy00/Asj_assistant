// Fetches a URL's full content for chat/index.ts's fetch_full_document
// tool, so the agent can read an authoritative source in full instead of
// answering from a web-search snippet. HTML is stripped down to readable
// text with a small hand-rolled parser (no DOM/HTML library dependency,
// matching this project's general preference for lightweight parsing) —
// cheap enough to always do synchronously, in-turn.
//
// PDFs are different, and this took a few rounds of live testing to get
// right. pdf-parse/pdf.js text extraction pays most of its cost just
// *opening* a document (xref table, embedded fonts) — confirmed live with
// a genuine ~1.3MB GE CT660 site-planning PDF (dense per-page CAD
// drawings/font subsets) that tripped Supabase's per-request CPU-time
// limit ("CPU Time exceeded") even after capping pages parsed down to 10.
// That's a hard, uncatchable isolate kill — not a JS exception — and
// (also confirmed live) running the extraction in a separate Edge
// Function invocation doesn't dodge it either: a function called
// synchronously and awaited from within another function's request
// shares that request's CPU-time budget rather than getting its own, so
// the whole /chat turn dies with it either way.
//
// So PDFs never get parsed synchronously here at all. fetchFullDocument
// just downloads the bytes and hands them back unparsed (deferredPdfBytes)
// for chat/index.ts to queue as background work via EdgeRuntime.waitUntil
// — the same mechanism process-file already uses to extract full,
// uncapped text from uploaded PDFs (including large ones, across the
// ~2000-document bulk import) without ever hitting this limit, because
// background/waitUntil work isn't on the hook to respond quickly and
// isn't charged against the same budget. The tradeoff: a PDF can't be
// quoted from in the turn that first finds it, only cached for next time.
// The system prompt is expected to have the agent say that plainly.

import { extractText } from "./extract_text.ts";

const MAX_FETCH_BYTES = 15_000_000; // 15MB — generous for a spec PDF, not unbounded
const MAX_RETURNED_CHARS = 60_000; // keep the follow-up Claude call's context reasonable
const FETCH_TIMEOUT_MS = 20_000;

export interface FetchedDocument {
  text: string;
  truncated: boolean;
  contentType: string;
  /** Set only for PDFs: raw bytes, extraction deliberately deferred — see
   * module comment. Caller queues background extraction+caching with
   * these; `text` is empty and `truncated` is false in this case. */
  deferredPdfBytes?: Uint8Array;
}

function stripHtml(html: string): string {
  let text = html
    // Drop non-content elements entirely, tags and contents both.
    .replace(/<(script|style|noscript|svg|head)[^>]*>[\s\S]*?<\/\1>/gi, " ")
    // Block-level boundaries become newlines so paragraphs/rows don't run together.
    .replace(/<(br|\/p|\/div|\/li|\/tr|\/h[1-6])\s*\/?>/gi, "\n")
    // Table cells/list items get a separator so a spec table reads as
    // recognizable rows rather than one run-on line.
    .replace(/<(td|th)[^>]*>/gi, " | ")
    .replace(/<[^>]+>/g, " ");

  const entities: Record<string, string> = {
    "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
    "&quot;": '"', "&#39;": "'", "&apos;": "'",
  };
  for (const [entity, replacement] of Object.entries(entities)) {
    text = text.replaceAll(entity, replacement);
  }
  text = text.replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)));

  return text
    .split("\n")
    .map((line) => line.replace(/[ \t]+/g, " ").trim())
    .filter((line) => line.length > 0)
    .join("\n");
}

export async function fetchFullDocument(url: string): Promise<FetchedDocument> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

  try {
    const resp = await fetch(url, {
      signal: controller.signal,
      headers: {
        // Some manufacturer sites block requests with no browser-like UA.
        "User-Agent":
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
      },
    });
    if (!resp.ok) {
      throw new Error(`Fetching ${url} returned HTTP ${resp.status}`);
    }

    const contentType = resp.headers.get("content-type") ?? "";
    const contentLength = Number(resp.headers.get("content-length") ?? "0");
    if (contentLength > MAX_FETCH_BYTES) {
      throw new Error(`Document at ${url} is too large to fetch (${contentLength} bytes)`);
    }

    const buf = await resp.arrayBuffer();
    if (buf.byteLength > MAX_FETCH_BYTES) {
      throw new Error(`Document at ${url} is too large to fetch (${buf.byteLength} bytes)`);
    }
    const bytes = new Uint8Array(buf);
    const looksLikePdf = contentType.includes("application/pdf") || url.toLowerCase().endsWith(".pdf");
    console.log(
      `fetch_full_document: ${bytes.length} bytes from ${url} (content-type ${contentType}, looksLikePdf=${looksLikePdf})`,
    );

    if (looksLikePdf) {
      // Extraction deliberately NOT done here — see module comment.
      return { text: "", truncated: false, contentType: "application/pdf", deferredPdfBytes: bytes };
    }

    const html = new TextDecoder("utf-8").decode(bytes);
    const stripStart = performance.now();
    const text = stripHtml(html);
    console.log(`fetch_full_document: stripHtml took ${Math.round(performance.now() - stripStart)}ms for ${html.length} chars`);
    const truncated = text.length > MAX_RETURNED_CHARS;
    return {
      text: truncated ? text.slice(0, MAX_RETURNED_CHARS) : text,
      truncated,
      contentType: "text/html",
    };
  } finally {
    clearTimeout(timeout);
  }
}

/** Full, uncapped PDF text extraction — only ever called from background
 * (EdgeRuntime.waitUntil) work, never inline in a request/response path.
 * Mirrors process-file's extraction of uploaded PDFs, which has run
 * uncapped in the background across ~2000 real documents without hitting
 * the CPU-time limit that bit the synchronous path (see module comment). */
export async function extractPdfTextInBackground(bytes: Uint8Array, url: string): Promise<string> {
  return await extractText(bytes, "application/pdf", url);
}
