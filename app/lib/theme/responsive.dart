import 'package:flutter/material.dart';

/// A gentle, screen-width-based scale for spacing and custom-widget sizing,
/// so the UI doesn't look cramped on small phones or sparse on large ones.
///
/// Material widgets (AppBar, NavigationBar, ListTile, ChoiceChip, etc.)
/// already adapt to the device reasonably on their own — this is for the
/// custom widgets in this app (message bubbles, the composer, thumbnails,
/// library rows) that use explicit sizes.
extension ResponsiveContext on BuildContext {
  static const double _baselineWidth = 390.0; // a common mid-size phone
  static const double _minScale = 0.85;
  static const double _maxScale = 1.3;

  double get screenWidth => MediaQuery.sizeOf(this).width;
  double get screenHeight => MediaQuery.sizeOf(this).height;

  /// Scale factor derived from actual device width, clamped so nothing
  /// balloons on a tablet or shrinks to illegibility on a small phone.
  double get scale => (screenWidth / _baselineWidth).clamp(_minScale, _maxScale);

  /// Scales a value designed against the [_baselineWidth] reference.
  double s(double value) => value * scale;
}
