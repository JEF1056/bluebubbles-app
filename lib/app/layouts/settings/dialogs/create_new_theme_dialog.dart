import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

Future<void> showCreateNewThemeDialog(
  BuildContext context,
  bool isDarkMode,
  ThemeStruct currentTheme,
  Function(ThemeStruct) onComplete,
) async {
  final name = await showBBInputDialog(
    context: context,
    title: "Create New Theme",
    icon: SettingsSvc.settings.skin.value == Skins.iOS ? CupertinoIcons.paintbrush : Icons.palette_outlined,
    body: "Your new theme will copy the colors currently displayed in the advanced theming menu.",
    labelText: "Theme Name",
    hintText: "e.g. Midnight Blue",
    confirmText: "Create Theme",
    textCapitalization: TextCapitalization.words,
    validator: (value) {
      if (value == null || value.isEmpty || ThemeStruct.findOne(value) != null) {
        return "Please use a unique name for your new theme";
      }
      return null;
    },
  );
  if (name == null) return;
  ThemeData finalData = currentTheme.data;
  final tuple = ThemeSvc.getStructsFromData(finalData, finalData);
  finalData = isDarkMode ? tuple.dark : tuple.light;
  final newTheme = ThemeStruct(themeData: finalData, name: name);
  onComplete.call(newTheme);
}
