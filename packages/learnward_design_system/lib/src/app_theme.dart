import 'package:flutter/material.dart';

import 'tokens/app_radius.dart';
import 'tokens/app_typography.dart';

/// LearnWard's Material 3 theme.
///
/// Branding is deliberately neutral in Phase 0. Consumers should read colors
/// and text styles from [ThemeData] rather than hard-coding visual values.
abstract final class AppTheme {
  static const Color _seedColor = Color(0xFF376B5B);

  static ThemeData get light => _build(Brightness.light);

  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: brightness,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: colorScheme);

    return base.copyWith(
      scaffoldBackgroundColor: colorScheme.surface,
      textTheme: base.textTheme.copyWith(
        displaySmall: base.textTheme.displaySmall?.merge(
          AppTypography.displaySmall,
        ),
        titleLarge: base.textTheme.titleLarge?.merge(AppTypography.titleLarge),
        titleMedium: base.textTheme.titleMedium?.merge(
          AppTypography.titleMedium,
        ),
        bodyLarge: base.textTheme.bodyLarge?.merge(AppTypography.bodyLarge),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
      ),
    );
  }
}
