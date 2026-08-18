// Audio/video transcription via Gemini's native audio understanding —
// replaces the never-deployed WhisperX worker (see worker/README.md, now
// superseded). Runs directly inside process-file's background work; unlike
// WhisperX, this needs no separate persistent server — it's a plain HTTPS
// call, so it fits the same EdgeRuntime.waitUntil pattern already used for
// document processing.
//
// Uses the Gemini Files API (upload -> poll ACTIVE -> reference by URI)
// rather than inlining base64 audio in the request body: inline requests
// are capped around ~20MB, which real call recordings can exceed, while
// the Files API comfortably handles anything up to the 500MB the uploads
// bucket itself allows.
//
// Request/response field casing (camelCase for resource fields and the
// generateContent body, snake_case specifically for the upload-init body's
// "display_name") was verified directly against the live API while
// building this — Gemini's REST docs are inconsistent about this across
// pages, so this was confirmed empirically rather than guessed.

const GEMINI_API_BASE = "https://generativelanguage.googleapis.com";
// gemini-2.5-flash was retired for new callers as of this writing; Google's
// own 404 error names the replacement. Overridable via env so a future
// model swap doesn't need a code change.
const GEMINI_MODEL = Deno.env.get("GEMINI_MODEL") || "gemini-3.6-flash";
const POLL_INTERVAL_MS = 2000;
const POLL_MAX_ATTEMPTS = 60; // ~2 minutes waiting for the file to go ACTIVE

export interface TranscriptSegmentResult {
  speaker_label: string | null;
  start_time: number;
  end_time: number;
  text: string;
  low_confidence: boolean;
}

const TRANSCRIPTION_PROMPT =
  `Transcribe this recording in full. It's a phone or site-visit call in the medical imaging equipment maintenance trade, likely Egyptian Arabic mixed with English/French technical terms and brand names — transcribe mixed-language speech as it was actually spoken, don't translate it.

Break it into natural segments (roughly a sentence or a few sentences each). For each segment: identify the speaker as best you can distinguish voices, using consistent labels for the same voice throughout (SPEAKER_1, SPEAKER_2, ...) — if it's clearly a single speaker, just use SPEAKER_1 for everything. Give approximate start/end time in seconds.

Mark a segment "low_confidence": true only when you're genuinely unsure what was said (mumbling, overlapping speech, heavy background noise, or a technical term you can't make out) — not routinely, only when it's actually uncertain.`;

const RESPONSE_SCHEMA = {
  type: "OBJECT",
  properties: {
    segments: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          speaker_label: { type: "STRING" },
          start_time: { type: "NUMBER" },
          end_time: { type: "NUMBER" },
          text: { type: "STRING" },
          low_confidence: { type: "BOOLEAN" },
        },
        required: ["start_time", "end_time", "text", "low_confidence"],
      },
    },
  },
  required: ["segments"],
};

interface GeminiFile {
  name: string;
  uri: string;
  state: string;
}

async function uploadToGemini(
  apiKey: string,
  bytes: Uint8Array,
  mimeType: string,
  displayName: string,
): Promise<GeminiFile> {
  const startResp = await fetch(`${GEMINI_API_BASE}/upload/v1beta/files?key=${apiKey}`, {
    method: "POST",
    headers: {
      "X-Goog-Upload-Protocol": "resumable",
      "X-Goog-Upload-Command": "start",
      "X-Goog-Upload-Header-Content-Length": String(bytes.length),
      "X-Goog-Upload-Header-Content-Type": mimeType,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ file: { display_name: displayName } }),
  });
  if (!startResp.ok) {
    throw new Error(`Gemini upload init failed: ${startResp.status} ${await startResp.text()}`);
  }
  const uploadUrl = startResp.headers.get("x-goog-upload-url");
  if (!uploadUrl) throw new Error("Gemini upload init did not return an upload URL");

  const uploadResp = await fetch(uploadUrl, {
    method: "POST",
    headers: {
      "Content-Length": String(bytes.length),
      "X-Goog-Upload-Offset": "0",
      "X-Goog-Upload-Command": "upload, finalize",
    },
    body: bytes,
  });
  if (!uploadResp.ok) {
    throw new Error(`Gemini upload failed: ${uploadResp.status} ${await uploadResp.text()}`);
  }
  const uploaded = await uploadResp.json();
  return uploaded.file as GeminiFile;
}

async function waitUntilActive(apiKey: string, fileName: string): Promise<void> {
  for (let attempt = 0; attempt < POLL_MAX_ATTEMPTS; attempt++) {
    const resp = await fetch(`${GEMINI_API_BASE}/v1beta/${fileName}?key=${apiKey}`);
    if (!resp.ok) throw new Error(`Gemini file status check failed: ${resp.status}`);
    const data = await resp.json();
    if (data.state === "ACTIVE") return;
    if (data.state === "FAILED") throw new Error("Gemini failed to process the uploaded audio/video file.");
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }
  throw new Error("Timed out waiting for Gemini to finish processing the uploaded file.");
}

async function deleteGeminiFile(apiKey: string, fileName: string): Promise<void> {
  try {
    await fetch(`${GEMINI_API_BASE}/v1beta/${fileName}?key=${apiKey}`, { method: "DELETE" });
  } catch (e) {
    console.error("Failed to delete Gemini file (non-fatal, files auto-expire in 48h anyway):", e);
  }
}

export async function transcribeWithGemini(
  bytes: Uint8Array,
  mimeType: string,
  displayName: string,
): Promise<TranscriptSegmentResult[]> {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) throw new Error("GEMINI_API_KEY is not set");

  const file = await uploadToGemini(apiKey, bytes, mimeType, displayName);
  try {
    if (file.state !== "ACTIVE") await waitUntilActive(apiKey, file.name);

    const genResp = await fetch(
      `${GEMINI_API_BASE}/v1beta/models/${GEMINI_MODEL}:generateContent?key=${apiKey}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [{
            role: "user",
            parts: [
              { fileData: { mimeType, fileUri: file.uri } },
              { text: TRANSCRIPTION_PROMPT },
            ],
          }],
          generationConfig: {
            responseMimeType: "application/json",
            responseSchema: RESPONSE_SCHEMA,
          },
        }),
      },
    );
    if (!genResp.ok) {
      throw new Error(`Gemini transcription request failed: ${genResp.status} ${await genResp.text()}`);
    }
    const genData = await genResp.json();
    const text = genData.candidates?.[0]?.content?.parts?.find((p: { text?: string }) => p.text)?.text;
    if (!text) throw new Error("Gemini returned no transcription content.");

    const parsed = JSON.parse(text) as { segments: TranscriptSegmentResult[] };
    return (parsed.segments ?? []).filter((s) => s.text?.trim());
  } finally {
    await deleteGeminiFile(apiKey, file.name);
  }
}
