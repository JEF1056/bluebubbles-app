import 'dart:convert';

import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

abstract final class FindMyRawDataDialog {
  static Future<void> show(BuildContext context, dynamic item) {
    const encoder = JsonEncoder.withIndent("     ");
    final str = encoder.convert(item.toJson());

    return showBBDialog<void>(
      context: context,
      title: "Raw FindMy Data",
      icon: Icons.data_object_rounded,
      content: SizedBox(
        width: NavigationSvc.width(context) * 3 / 5,
        height: context.height * 1 / 4,
        child: Container(
          padding: const EdgeInsets.all(10.0),
          decoration: BoxDecoration(
            color: context.theme.colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(10)),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              str,
              style: context.theme.textTheme.bodyMedium,
            ),
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
  }
}
