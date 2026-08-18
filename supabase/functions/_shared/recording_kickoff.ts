// When a call recording gets its own dedicated chat (see chat_screen.dart's
// _handleAttach and conversations.seed_file_id), the whole point is for the
// agent to focus fully on that recording — so once its transcript is ready,
// the agent opens the conversation itself rather than sitting silent until
// the user happens to say something. This is the one place in the backend
// that posts an agent message without a preceding user message.

// deno-lint-ignore no-explicit-any
type SupabaseClient = any;
// deno-lint-ignore no-explicit-any
type FileRow = any;

import { callClaude } from "./anthropic.ts";
import { buildSystemPrompt } from "./system_prompt.ts";
import { embed, toPgVector } from "./embeddings.ts";
import type { TranscriptSegmentResult } from "./gemini_transcribe.ts";

function formatTranscript(segments: TranscriptSegmentResult[]): string {
  return segments
    .map((s) => {
      const speaker = s.speaker_label ? `${s.speaker_label}: ` : "";
      const flag = s.low_confidence ? " [unclear — worth confirming]" : "";
      return `${speaker}${s.text}${flag}`;
    })
    .join("\n");
}

/**
 * Posts the opening agent message for a freshly-processed call recording's
 * dedicated chat, if this file is in fact that chat's seed file and nobody
 * has said anything in it yet. No-op otherwise (including if this file was
 * uploaded into an ordinary, non-dedicated conversation, which is the
 * common case for everything that isn't a call recording).
 */
export async function maybePostRecordingKickoff(
  supabase: SupabaseClient,
  file: FileRow,
  outcome: { status: "completed"; segments: TranscriptSegmentResult[] } | { status: "failed"; errorMessage: string },
): Promise<void> {
  if (!file.conversation_id) return;

  const { data: conversation } = await supabase
    .from("conversations")
    .select("id, seed_file_id")
    .eq("id", file.conversation_id)
    .maybeSingle();
  if (!conversation || conversation.seed_file_id !== file.id) return;

  const { data: existingMessages } = await supabase
    .from("messages")
    .select("id")
    .eq("conversation_id", conversation.id)
    .limit(1);
  if (existingMessages && existingMessages.length > 0) return; // user already jumped in

  let ragContext: string;
  if (outcome.status === "completed") {
    const transcript = formatTranscript(outcome.segments);
    const lowConfidenceCount = outcome.segments.filter((s) => s.low_confidence).length;
    ragContext =
      `\n# You've just been handed a new call recording to look at\n` +
      `Its filename is "${file.filename}". Its full transcript is below (segments marked ` +
      `"[unclear — worth confirming]" are parts the transcription genuinely couldn't make out ` +
      `with confidence — ${lowConfidenceCount} such segment(s) here).\n\n` +
      `This is the very first message in this chat, and you're opening it, not replying to one. ` +
      `Open naturally, the way a colleague would after listening to a call together — a brief, ` +
      `genuinely useful take on what it was about, not a recitation of the transcript back to him. ` +
      `If anything is worth confirming (an unclear segment, an ambiguous part number or brand, ` +
      `something that sounds inconsistent with what you know), ask about it — but only if there's ` +
      `something real to ask, don't invent a question just to have one.\n\n${transcript}\n`;
  } else {
    ragContext =
      `\n# A call recording just failed to process\n` +
      `Its filename is "${file.filename}". The transcription attempt failed: ${outcome.errorMessage}\n\n` +
      `This is the very first message in this chat, and you're opening it, not replying to one. ` +
      `Tell him plainly and briefly that you weren't able to get anything usable out of the recording ` +
      `(don't recite the raw error) and ask him to either describe what the call was about or try ` +
      `re-uploading it — whichever's easier for him.\n`;
  }

  const systemPrompt = buildSystemPrompt(ragContext);
  const result = await callClaude({
    systemPrompt,
    messages: [{
      role: "user",
      content: "(Open the conversation now, per the instructions above.)",
    }],
    enableWebSearch: false,
  });

  const finalText = result.finalText.trim();
  if (!finalText) return;

  const { data: agentMessage } = await supabase
    .from("messages")
    .insert({
      conversation_id: conversation.id,
      role: "agent",
      content: finalText,
      thinking_content: result.thinkingText || null,
      replies_to_message_id: null,
      metadata: { kickoff: true, recording_outcome: outcome.status },
    })
    .select()
    .single();
  if (!agentMessage) return;

  try {
    const vec = await embed(finalText);
    await supabase.from("embeddings").upsert({
      source_type: "message",
      source_id: agentMessage.id,
      content_preview: finalText.slice(0, 2000),
      embedding: toPgVector(vec),
    }, { onConflict: "source_type,source_id" });
  } catch (e) {
    console.error("Failed to embed recording kickoff message:", e);
  }
}
