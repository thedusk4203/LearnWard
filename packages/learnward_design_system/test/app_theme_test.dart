import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

void main() {
  group('AppTheme', () {
    test('builds light and dark Material 3 themes', () {
      expect(AppTheme.light.brightness, Brightness.light);
      expect(AppTheme.dark.brightness, Brightness.dark);
      expect(AppTheme.light.useMaterial3, isTrue);
    });

    test('applies spacing and radius tokens', () {
      expect(AppSpacing.md, 16);
      expect(AppRadius.md, 12);
      expect(AppTypography.titleLarge.fontWeight, FontWeight.w600);
    });
  });
}
