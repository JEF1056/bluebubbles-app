import 'dart:convert';

import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

Future<bool> showCustomHeadersDialog(BuildContext context) async {
  final List<TextEditingController> keyControllers = [];
  final List<TextEditingController> valueControllers = [];
  if (SettingsSvc.settings.customHeaders.value.isNotEmpty) {
    SettingsSvc.settings.customHeaders.value.forEach((key, value) {
      keyControllers.add(TextEditingController(text: key));
      valueControllers.add(TextEditingController(text: value));
    });
  } else {
    keyControllers.add(TextEditingController());
    valueControllers.add(TextEditingController());
  }

  bool dialogOpen = true;
  try {
    final result = await showBBDialog<bool>(
      context: context,
      title: "Custom Headers",
      icon: SettingsSvc.settings.skin.value == Skins.iOS ? CupertinoIcons.slider_horizontal_3 : Icons.tune_outlined,
      content: StatefulBuilder(builder: (ctx, setState) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: ctx.mediaQuery.size.height * 0.3,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int index = 0; index < keyControllers.length; index++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: keyControllers[index],
                                decoration: const InputDecoration(
                                  labelText: "Key",
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: valueControllers[index],
                                decoration: const InputDecoration(
                                  labelText: "Value",
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: "Remove header",
                              icon: Icon(
                                SettingsSvc.settings.skin.value == Skins.iOS ? CupertinoIcons.trash : Icons.delete_outline,
                                color: ctx.theme.colorScheme.error,
                                size: 20,
                              ),
                              onPressed: () {
                                setState(() {
                                  keyControllers.removeAt(index).dispose();
                                  valueControllers.removeAt(index).dispose();
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  keyControllers.add(TextEditingController());
                  valueControllers.add(TextEditingController());
                });
              },
              icon: const Icon(Icons.add, size: 18),
              label: const Text("Add Header"),
            ),
          ],
        );
      }),
      actions: [
        BBDialogAction(
          text: "Cancel",
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
        BBDialogAction(
          text: "Save Headers",
          isDefault: true,
          onPressed: () async {
            final map = <String, String>{};
            keyControllers.forEachIndexed((index, element) {
              final keyController = element;
              final valueController = valueControllers[index];
              if (keyController.text.isNotEmpty && valueController.text.isNotEmpty) {
                map.addEntries([MapEntry(keyController.text, valueController.text)]);
              }
            });

            SettingsSvc.settings.customHeaders.value = map;
            await SettingsSvc.settings.saveOneAsync('customHeaders');
            await PrefsSvc.network.setCustomHeadersJson(jsonEncode(HttpSvc.headers));
            HttpSvc.updateHeaders();
            if (dialogOpen && context.mounted) {
              Navigator.of(context, rootNavigator: true).pop(true);
            }
          },
        ),
      ],
    ).whenComplete(() => dialogOpen = false);
    return result ?? false;
  } finally {
    for (final c in keyControllers) {
      c.dispose();
    }
    for (final c in valueControllers) {
      c.dispose();
    }
  }
}
