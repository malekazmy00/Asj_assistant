"""
Reference implementation for the real WhisperX pipeline — NOT wired into
main.py yet (see README.md "Going from stub to real WhisperX" for the
one-line swap once this worker has somewhere to run with enough compute).

Requires the commented-out deps in requirements.txt (torch, faster-whisper,
whisperx, pyannote.audio) and a Hugging Face token (HF_TOKEN) that has
accepted the gated model terms for:
  - pyannote/segmentation-3.0
  - pyannote/speaker-diarization-3.1

This is CPU-workable for short clips but meaningfully faster with a GPU.
Pick WHISPER_MODEL_SIZE based on what the deployment target can afford —
"small" or "medium" are reasonable CPU defaults; "large-v3" wants a GPU.
"""

import os
import tempfile

WHISPER_MODEL_SIZE = os.environ.get("WHISPER_MODEL_SIZE", "medium")
DEVICE = os.environ.get("WHISPERX_DEVICE", "cpu")  # "cuda" if a GPU is available
COMPUTE_TYPE = os.environ.get("WHISPERX_COMPUTE_TYPE", "int8")  # "float16" on GPU
LOW_CONFIDENCE_THRESHOLD = float(os.environ.get("LOW_CONFIDENCE_THRESHOLD", "0.6"))


def transcribe_real(audio_bytes: bytes, language: str | None = None) -> list[dict]:
    """
    Full pipeline: faster-whisper transcription -> wav2vec2 word alignment
    -> pyannote speaker diarization -> merged, speaker-labelled segments.

    language=None lets Whisper auto-detect — useful given the mix of
    Egyptian Arabic and English/French technical jargon in this domain, but
    pin language="ar" if auto-detect proves unreliable in practice.
    """
    import whisperx  # noqa: F401  (imported lazily — heavy optional dep)

    hf_token = os.environ["HF_TOKEN"]

    with tempfile.NamedTemporaryFile(suffix=".audio") as tmp:
        tmp.write(audio_bytes)
        tmp.flush()

        # 1. Transcribe (faster-whisper under the hood).
        model = whisperx.load_model(WHISPER_MODEL_SIZE, DEVICE, compute_type=COMPUTE_TYPE)
        audio = whisperx.load_audio(tmp.name)
        result = model.transcribe(audio, language=language)

        # 2. Word-level alignment (wav2vec2), improves segment timing/confidence.
        align_model, metadata = whisperx.load_align_model(
            language_code=result["language"], device=DEVICE
        )
        result = whisperx.align(
            result["segments"], align_model, metadata, audio, DEVICE, return_char_alignments=False
        )

        # 3. Speaker diarization (pyannote), gated models via HF_TOKEN.
        diarize_model = whisperx.diarize.DiarizationPipeline(use_auth_token=hf_token, device=DEVICE)
        diarize_segments = diarize_model(audio)
        result = whisperx.assign_word_speakers(diarize_segments, result)

    segments = []
    for seg in result["segments"]:
        word_scores = [w.get("score") for w in seg.get("words", []) if w.get("score") is not None]
        avg_confidence = sum(word_scores) / len(word_scores) if word_scores else None
        segments.append(
            {
                "start_time": seg["start"],
                "end_time": seg["end"],
                "speaker_label": seg.get("speaker"),
                "text": seg["text"].strip(),
                "confidence": avg_confidence,
                # Egyptian Arabic + technical jargon will trip up ASR confidence
                # regularly — flag anything under threshold so the agent treats
                # it as worth double-checking with the user, rather than
                # trusting it blindly (per the product brief).
                "low_confidence": avg_confidence is not None and avg_confidence < LOW_CONFIDENCE_THRESHOLD,
            }
        )
    return segments
