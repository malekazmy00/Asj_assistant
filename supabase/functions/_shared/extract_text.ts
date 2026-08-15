// Text extraction for uploaded documents. Plain text/markdown is handled
// directly; PDF and Word documents use small pure-JS npm packages (no
// native deps, so they run fine in the Edge Runtime). If a format ever
// fails to extract, the file is marked `failed` with the error message
// rather than silently producing nothing — see process-file/index.ts.

export async function extractText(
  bytes: Uint8Array,
  mimeType: string,
  filename: string,
): Promise<string> {
  const ext = filename.split(".").pop()?.toLowerCase() ?? "";

  if (mimeType === "text/plain" || mimeType === "text/markdown" || ext === "txt" || ext === "md") {
    return new TextDecoder("utf-8").decode(bytes);
  }

  if (mimeType === "application/pdf" || ext === "pdf") {
    const { default: pdfParse } = await import("npm:pdf-parse@1.1.1");
    const result = await pdfParse(bytes);
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
