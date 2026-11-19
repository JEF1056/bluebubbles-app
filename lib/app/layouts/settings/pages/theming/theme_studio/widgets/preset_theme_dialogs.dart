import 'package:bluebubbles/app/layouts/settings/pages/theming/theme_studio/theme_studio_panel.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:flutter/material.dart';

import 'preset_theme_actions.dart';

class PresetThemeDialogs {
  final ThemeStudioController controller;
  final bool isForDark;
  final void Function(BuildContext context) showImportDialog;

  PresetThemeDialogs({
    required this.controller,
    required this.isForDark,
    required this.showImportDialog,
  });

  void showContextMenu(BuildContext context, ThemeStruct theme) {
    final isCustom = !theme.isPreset;
    showBBBottomSheet<void>(
      context: context,
      title: theme.name,
      icon: Icons.palette_outlined,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text(PresetThemeActions.cloneLabel),
            subtitle: const Text("Create a copy of this theme"),
            onTap: () {
              Navigator.of(ctx, rootNavigator: true).pop();
              showCloneDialog(context, theme);
            },
          ),
          if (isCustom) ...[
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text(PresetThemeActions.renameLabel),
              onTap: () {
                Navigator.of(ctx, rootNavigator: true).pop();
                showRenameDialog(context, theme);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
              title: Text(PresetThemeActions.deleteLabel,
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () {
                Navigator.of(ctx, rootNavigator: true).pop();
                confirmDelete(context, theme);
              },
            ),
          ],
        ],
      ),
    );
  }

  Future<void> showCloneDialog(BuildContext context, ThemeStruct source) async {
    final name = await showBBInputDialog(
      context: context,
      title: "Clone \"${source.name}\"",
      icon: Icons.copy_outlined,
      initialValue: "${source.name} Copy",
      labelText: "New Theme Name",
      confirmText: "Clone",
      validator: (v) => PresetThemeActions.validateThemeName(v ?? ""),
    );
    if (name == null) return;
    controller.cloneTheme(name.trim(), source);
  }

  Future<void> showRenameDialog(BuildContext context, ThemeStruct theme) async {
    controller.applyTheme(context, theme);
    final newName = await showBBInputDialog(
      context: context,
      title: "Rename \"${theme.name}\"",
      icon: Icons.edit_outlined,
      initialValue: theme.name,
      labelText: "New Name",
      confirmText: "Rename",
      validator: (v) => (v == null || v.trim().isEmpty) ? "Name cannot be empty" : null,
    );
    if (newName == null || !context.mounted) return;
    final ok = await controller.renameTheme(context, newName.trim());
    if (!ok) showSnackbar("Error", "Could not rename — name is empty or already taken", type: SnackbarType.error);
  }

  void confirmDelete(BuildContext context, ThemeStruct theme) {
    showBBDialog(
      context: context,
      title: "Delete Theme",
      icon: Icons.delete_outline,
      iconColor: Theme.of(context).colorScheme.error,
      body: "Delete \"${theme.name}\"? This cannot be undone.",
      actions: [
        BBDialogAction(
          text: "Cancel",
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
        BBDialogAction(
          text: "Delete",
          isDestructive: true,
          color: Theme.of(context).colorScheme.error,
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop();
            controller.applyTheme(context, theme);
            controller.deleteTheme(context);
          },
        ),
      ],
    );
  }

  Future<void> showCreateDialog(BuildContext context) async {
    final name = await showBBInputDialog(
      context: context,
      title: "New ${isForDark ? 'Dark' : 'Light'} Theme",
      icon: Icons.palette_outlined,
      labelText: "Theme Name",
      hintText: "e.g. My Custom Theme",
      confirmText: "Create",
      validator: (v) => PresetThemeActions.validateThemeName(v ?? ""),
    );
    if (name == null || !context.mounted) return;
    controller.createTheme(context, name.trim(), forDark: isForDark);
  }
}
