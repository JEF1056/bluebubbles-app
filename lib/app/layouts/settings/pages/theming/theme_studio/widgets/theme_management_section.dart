import 'dart:convert';
import 'package:universal_io/io.dart' as dart_io;

import 'package:bluebubbles/app/layouts/settings/pages/theming/theme_studio/theme_studio_panel.dart';
import 'package:bluebubbles/app/layouts/settings/pages/theming/theme_studio/widgets/color_editor_tile.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/next_button.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Rename / Export / Import / Generate from seed / Generate from image /
/// Reset / Delete actions for the active theme.
class ThemeManagementSection extends StatelessWidget {
  const ThemeManagementSection({super.key, required this.controller});

  final ThemeStudioController controller;

  bool get _isCustom => !controller.activeTheme.isPreset;

  @override
  Widget build(BuildContext context) {
    final tileColor = context.tileColor;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Always-available actions ───────────────────────────────────────
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Material(
              color: tileColor,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_isCustom) ...[
                    SettingsTile(
                      title: "Rename",
                      subtitle: "Change the name of \"${controller.activeTheme.name}\"",
                      leading: const SettingsLeadingIcon(
                        iosIcon: Icons.edit_outlined,
                        materialIcon: Icons.edit_outlined,
                        containerColor: Colors.teal,
                      ),
                      trailing: const NextButton(),
                      onTap: () => _showRenameDialog(context),
                    ),
                    const SettingsDivider(padding: EdgeInsets.only(left: 56)),
                  ],
                  SettingsTile(
                    title: "Export Theme",
                    subtitle: "Share this theme as a JSON file",
                    leading: const SettingsLeadingIcon(
                      iosIcon: Icons.share_outlined,
                      materialIcon: Icons.share_outlined,
                      containerColor: Colors.green,
                    ),
                    onTap: () => _exportTheme(context),
                  ),
                  const SettingsDivider(padding: EdgeInsets.only(left: 56)),
                  SettingsTile(
                    title: "Generate from Seed Color",
                    subtitle: "Build a full color palette from a single color",
                    leading: const SettingsLeadingIcon(
                      iosIcon: Icons.colorize_outlined,
                      materialIcon: Icons.colorize_outlined,
                      containerColor: Colors.purple,
                    ),
                    trailing: _isCustom ? const NextButton() : null,
                    onTap: _isCustom ? () => _generateFromSeed(context) : null,
                  ),
                  const SettingsDivider(padding: EdgeInsets.only(left: 56)),
                  SettingsTile(
                    title: "Generate from Image",
                    subtitle: "Build a color palette from a PNG or JPEG",
                    leading: const SettingsLeadingIcon(
                      iosIcon: Icons.image_outlined,
                      materialIcon: Icons.image_outlined,
                      containerColor: Colors.deepPurple,
                    ),
                    trailing: _isCustom ? const NextButton() : null,
                    onTap: _isCustom ? () => controller.generateFromImage(context) : null,
                  ),
                  if (_isCustom) ...[
                    const SettingsDivider(padding: EdgeInsets.only(left: 56)),
                    SettingsTile(
                      title: "Toggle Gradient Background",
                      subtitle: "Animated gradient in the message view",
                      leading: SettingsLeadingIcon(
                        iosIcon: Icons.gradient_outlined,
                        materialIcon: Icons.gradient_outlined,
                        containerColor: controller.activeTheme.gradientBg ? context.theme.colorScheme.primary : null,
                      ),
                      trailing: Switch(
                        value: controller.activeTheme.gradientBg,
                        onChanged: (v) async => await _toggleGradient(context, v),
                      ),
                      onTap: () async => await _toggleGradient(context, !controller.activeTheme.gradientBg),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // ── Danger zone ────────────────────────────────────────────────────
          if (_isCustom) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Material(
                color: tileColor,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SettingsTile(
                      title: "Reset Colors to Default",
                      subtitle: "Overwrite all colors with the built-in defaults",
                      leading: SettingsLeadingIcon(
                        iosIcon: Icons.restart_alt,
                        materialIcon: Icons.restart_alt,
                        containerColor: context.theme.colorScheme.error,
                      ),
                      onTap: () => _confirmAction(
                        context,
                        title: "Reset Colors",
                        message:
                            "This will overwrite all color customizations in \"${controller.activeTheme.name}\" with the built-in defaults. This cannot be undone.",
                        confirmLabel: "Reset",
                        isDestructive: true,
                        onConfirm: () => controller.resetToDefault(context),
                      ),
                    ),
                    const SettingsDivider(padding: EdgeInsets.only(left: 56)),
                    SettingsTile(
                      title: "Delete Theme",
                      subtitle: "Permanently remove \"${controller.activeTheme.name}\"",
                      leading: SettingsLeadingIcon(
                        iosIcon: Icons.delete_outline,
                        materialIcon: Icons.delete_outline,
                        containerColor: context.theme.colorScheme.error,
                      ),
                      onTap: () => _confirmAction(
                        context,
                        title: "Delete Theme",
                        message:
                            "Are you sure you want to delete \"${controller.activeTheme.name}\"? This cannot be undone.",
                        confirmLabel: "Delete",
                        isDestructive: true,
                        onConfirm: () => controller.deleteTheme(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Action handlers ──────────────────────────────────────────────────────────

  Future<void> _showRenameDialog(BuildContext context) async {
    final name = await showBBInputDialog(
      context: context,
      title: "Rename Theme",
      icon: Icons.edit_outlined,
      initialValue: controller.activeTheme.name,
      labelText: "New Name",
      confirmText: "Rename",
      validator: (v) {
        final trimmed = v?.trim() ?? '';
        if (trimmed.isEmpty) return "Name cannot be empty";
        if (ThemeStruct.findOne(trimmed) != null) return "A theme named \"$trimmed\" already exists";
        return null;
      },
    );
    if (name == null || !context.mounted) return;
    await controller.renameTheme(context, name.trim());
  }

  Future<void> _exportTheme(BuildContext context) async {
    final json = controller.exportThemeJson();
    final themeName = controller.activeTheme.name.replaceAll(RegExp(r'[^\w\s]'), '').trim();
    final fileName = 'bb_theme_${themeName.replaceAll(' ', '_').toLowerCase()}.json';

    if (kIsWeb) {
      downloadBytes(Uint8List.fromList(utf8.encode(json)), fileName, mimeType: 'application/json');
    } else if (kIsDesktop) {
      // Desktop: show JSON in a dialog so the user can copy it, since share_plus
      // does not support file sharing on desktop.
      showBBDialog(
        context: context,
        title: "Export — $themeName",
        icon: Icons.ios_share_outlined,
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                "Copy the JSON below to share this theme. Import it on another device using the Import button in the Presets section.",
                style: context.theme.textTheme.bodySmall?.copyWith(color: context.theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  color: context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.theme.colorScheme.outline.withValues(alpha: 0.3)),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    json,
                    style: context.theme.textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          BBDialogAction(
            text: "Close",
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
          ),
          BBDialogAction(
            text: "Copy JSON",
            isDefault: true,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: json));
              if (context.mounted) {
                showCopiedToast("Theme JSON copied to clipboard");
                Navigator.of(context, rootNavigator: true).pop();
              }
            },
          ),
        ],
      );
    } else {
      try {
        final dir = await getTemporaryDirectory();
        final file = dart_io.File('${dir.path}/$fileName');
        await file.writeAsString(json);
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
      } catch (e) {
        showSnackbar("Error", "Could not export theme: $e", type: SnackbarType.error);
      }
    }
  }

  Future<void> _generateFromSeed(BuildContext context) async {
    final picked = await showColorPickerDialog(context, context.theme.colorScheme.primary);
    if (picked != null) {
      controller.generateFromSeed(context, picked);
    }
  }

  Future<void> _toggleGradient(BuildContext context, bool value) async {
    controller.activeTheme.gradientBg = value;
    controller.activeTheme.save();
    if (controller.isDark.value) {
      await ThemeSvc.changeTheme(context, dark: controller.activeTheme);
    } else {
      await ThemeSvc.changeTheme(context, light: controller.activeTheme);
    }
    controller.bump();
  }

  void _confirmAction(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    bool isDestructive = false,
    required VoidCallback onConfirm,
  }) {
    showBBDialog(
      context: context,
      title: title,
      body: message,
      actions: [
        BBDialogAction(
          text: "Cancel",
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
        BBDialogAction(
          text: confirmLabel,
          isDefault: !isDestructive,
          isDestructive: isDestructive,
          color: isDestructive ? context.theme.colorScheme.error : null,
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop();
            onConfirm();
          },
        ),
      ],
    );
  }
}
