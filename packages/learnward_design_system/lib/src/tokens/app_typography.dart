import 'package:flutter/material.dart';

/// Typography entry point for LearnWard.
///
/// These are intentionally neutral defaults. Final brand typography arrives
/// with brand design, not during engineering bootstrap.
abstract final class AppTypography {
  static const TextStyle displaySmall = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w700,
    height: 1.15,
    letterSpacing: -0.8,
  );

  static const TextStyle titleLarge = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );

  static const TextStyle titleMedium = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.35,
  );

  static const TextStyle bodyLarge = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );
}
