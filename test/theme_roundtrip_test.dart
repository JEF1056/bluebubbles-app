import 'package:bluebubbles/database/io/theme.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:bluebubbles/services/ui/theme/themes_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ThemeStruct round-trip preserves M3 surfaceContainer roles and Google Messages bubbles', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final theme = ThemesService.materialYouTheme(brightness);
      final roundTripped = ThemeStruct.fromMap(
        ThemeStruct(name: 'Test', themeData: theme).toMap(),
      );

      final expected = theme.colorScheme;
      final actual = roundTripped.data.colorScheme;
      expect(actual.surfaceContainerLowest, expected.surfaceContainerLowest);
      expect(actual.surfaceContainerLow, expected.surfaceContainerLow);
      expect(actual.surfaceContainer, expected.surfaceContainer);
      expect(actual.surfaceContainerHigh, expected.surfaceContainerHigh);
      expect(actual.surfaceContainerHighest, expected.surfaceContainerHighest);
      expect(actual.outlineVariant, expected.outlineVariant);

      final bubbles = roundTripped.data.extension<BubbleColors>()!;
      if (brightness == Brightness.dark) {
        expect(bubbles.iMessageBubbleColor, expected.primaryContainer);
        expect(bubbles.oniMessageBubbleColor, expected.onPrimaryContainer);
        expect(bubbles.receivedBubbleColor, expected.surfaceContainerHighest);
      } else {
        expect(bubbles.iMessageBubbleColor, expected.primary);
        expect(bubbles.oniMessageBubbleColor, expected.onPrimary);
        expect(bubbles.receivedBubbleColor, expected.surfaceContainerHigh);
      }
    }
  });
}
