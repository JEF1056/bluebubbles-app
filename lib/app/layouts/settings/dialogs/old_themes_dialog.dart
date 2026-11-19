import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

// ignore: deprecated_member_use_from_same_package
Future<void> showOldThemesDialog(BuildContext context, List<ThemeObject> oldThemes, Function() clearOld) {
  final iOS = SettingsSvc.settings.skin.value == Skins.iOS;
  return showBBDialog<void>(
    context: context,
    title: "Old Themes",
    icon: iOS ? CupertinoIcons.paintbrush : Icons.palette_outlined,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: Text(
            "Tap an old theme to view its colors",
            style: context.theme.textTheme.bodySmall?.copyWith(color: context.theme.colorScheme.onSurfaceVariant),
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: context.mediaQuery.size.height * 0.4,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (int index = 0; index < oldThemes.length; index++)
                  ListTile(
                    key: ValueKey(oldThemes[index].name),
                    mouseCursor: MouseCursor.defer,
                    title: Text(oldThemes[index].name ?? "Unknown Theme", style: context.theme.textTheme.bodyLarge),
                    onTap: () {
                      final colorNames = ThemeColors.Colors.reversed.toList();
                      showBBDialog(
                        context: context,
                        title: "${oldThemes[index].name ?? "Unknown Theme"} Colors",
                        icon: iOS ? CupertinoIcons.color_filter : Icons.color_lens_outlined,
                        content: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: context.mediaQuery.size.height * 0.4,
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (int index2 = 0; index2 < 4; index2++)
                                  Builder(builder: (ctx) {
                                    final color = oldThemes[index]
                                        .entries
                                        .firstWhere((element) => element.name == colorNames[index2])
                                        .color!;
                                    final hex = color.hex;
                                    return ListTile(
                                      key: ValueKey(colorNames[index2]),
                                      mouseCursor: MouseCursor.defer,
                                      title: Text(colorNames[index2], style: ctx.theme.textTheme.bodyLarge),
                                      subtitle: Text(hex),
                                      leading: Container(
                                        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                                        height: 30,
                                        width: 30,
                                      ),
                                      onTap: () {
                                        Clipboard.setData(ClipboardData(text: hex));
                                        showCopiedToast("Hex code copied to clipboard");
                                      },
                                    );
                                  }),
                              ],
                            ),
                          ),
                        ),
                        actions: [
                          BBDialogAction(
                            text: "Close",
                            isDefault: true,
                            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                          ),
                        ],
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
    actions: [
      BBDialogAction(
        text: "Delete Old",
        isDestructive: true,
        onPressed: () {
          Database.themeObjects.removeAll();
          Database.themeEntries.removeAll();
          clearOld();
          Navigator.of(context, rootNavigator: true).pop();
        },
      ),
      BBDialogAction(
        text: "Close",
        isDefault: true,
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    ],
  );
}
