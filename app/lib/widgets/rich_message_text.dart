import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show Bidi;

/// Renders message content with the light structure Claude naturally
/// produces (numbered/bulleted lists, **bold**) instead of dumping markdown
/// syntax as literal text — and, line by line, picks the correct paragraph
/// direction via [Bidi.hasAnyRtl] rather than inheriting one ambient
/// direction for the whole message.
///
/// That per-line check is deliberate: a line is treated as RTL if it
/// contains *any* Arabic, even when it also contains English words or
/// numbers, matching how this app's users actually write (Egyptian Arabic
/// sentences with English/French technical terms embedded mid-sentence).
/// Estimating "majority" direction by character count would flip such
/// lines to LTR and reproduce exactly the bug this widget exists to fix.
class RichMessageText extends StatelessWidget {
  final String content;
  final TextStyle style;

  const RichMessageText({super.key, required this.content, required this.style});

  static final _numberedRe = RegExp(r'^(\d+)[.\)]\s+(.*)$');
  static final _bulletRe = RegExp(r'^[-*•]\s+(.*)$');
  static final _boldRe = RegExp(r'\*\*(.+?)\*\*');

  TextDirection _directionFor(String text) =>
      Bidi.hasAnyRtl(text) ? TextDirection.rtl : TextDirection.ltr;

  List<InlineSpan> _inlineSpans(String text) {
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _boldRe.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      spans.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w800)));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    if (spans.isEmpty) spans.add(TextSpan(text: text));
    return spans;
  }

  Widget _paragraphLine(String text) {
    final dir = _directionFor(text);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text.rich(
        TextSpan(style: style, children: _inlineSpans(text)),
        textDirection: dir,
        textAlign: TextAlign.start,
      ),
    );
  }

  Widget _listLine(String marker, String text) {
    final dir = _directionFor(text);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        textDirection: dir,
        children: [
          SizedBox(
            width: 22,
            child: Text(marker, style: style.copyWith(fontWeight: FontWeight.w700), textDirection: dir),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(style: style, children: _inlineSpans(text)),
              textDirection: dir,
              textAlign: TextAlign.start,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lines = content.split('\n');
    final children = <Widget>[];

    for (final line in lines) {
      if (line.trim().isEmpty) {
        children.add(SizedBox(height: (style.fontSize ?? 15) * 0.5));
        continue;
      }

      final numMatch = _numberedRe.firstMatch(line);
      final bulletMatch = _bulletRe.firstMatch(line);

      if (numMatch != null) {
        children.add(_listLine('${numMatch.group(1)}.', numMatch.group(2)!));
      } else if (bulletMatch != null) {
        children.add(_listLine('•', bulletMatch.group(1)!));
      } else {
        children.add(_paragraphLine(line));
      }
    }

    // IntrinsicWidth + stretch: the block sizes to its widest line, then
    // every line (including narrower/differently-directioned ones)
    // expands to that same width so each can align — start or end,
    // per its own direction — inside a shared block width, the way a
    // real chat bubble should.
    return IntrinsicWidth(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}
