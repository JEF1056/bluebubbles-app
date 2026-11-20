import 'dart:math';

import 'package:bluebubbles/app/components/wallpaper/wallpaper_contrast.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state.dart';

import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

class MessageTimestamp extends StatelessWidget {
  const MessageTimestamp({super.key, required this.controller, required this.cvController});

  final MessageState controller;
  final ConversationViewController cvController;

  Message get message => controller.message;

  static String formatMaterialTimestamp(
    DateTime? dateCreated, {
    DateTime? now,
    bool use24Hr = false,
  }) {
    if (dateCreated == null || dateCreated.millisecondsSinceEpoch == 0) return "";
    final ref = now ?? DateTime.now();
    final local = dateCreated.toLocal();
    final timeStr = use24Hr ? DateFormat.Hm().format(local) : DateFormat.jm().format(local);
    final today = DateTime(ref.year, ref.month, ref.day);
    final day = DateTime(local.year, local.month, local.day);
    final diffDays = today.difference(day).inDays;
    if (diffDays == 0) return "   $timeStr";
    final dateStr = diffDays > 0 && diffDays < 7
        ? DateFormat("EEE").format(local)
        : (local.year == ref.year ? DateFormat.MMMd().format(local) : DateFormat.yMd().format(local));
    return "   $dateStr\n   $timeStr";
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // Use MessageState observable for reactivity
      final dateCreated = controller.dateCreated.value;
      final skin = SettingsSvc.settings.skin.value;
      final isMaterial = skin == Skins.Material;
      final String time;
      final bool oneLine;
      if (isMaterial) {
        time = formatMaterialTimestamp(dateCreated, use24Hr: SettingsSvc.settings.use24HrFormat.value);
        oneLine = !time.contains('\n');
      } else {
        oneLine = skin == Skins.Samsung ? true : buildDate(dateCreated) == buildTime(dateCreated);
        time = oneLine
            ? "   ${buildTime(dateCreated)}"
            : "   ${buildDate(dateCreated)}\n   ${buildTime(dateCreated).toLowerCase()}";
      }
      final hasBackground = ChatStateScope.maybeOf(context)?.hasCustomWallpaper ?? false;
      final fallbackColor = isMaterial ? context.theme.colorScheme.onSurfaceVariant : context.theme.colorScheme.outline;
      return AnimatedContainer(
        duration: Duration(milliseconds: cvController.timestampOffset.value == 0 ? 150 : 0),
        width: skin == Skins.Samsung
            ? null
            : min(max(-cvController.timestampOffset.value, 0), 70),
        child: Offstage(
          offstage: skin != Skins.Samsung && cvController.timestampOffset.value == 0,
          child: Text(
            time,
            style: WallpaperContrast.unbubbledStyle(
              context.theme.textTheme.labelSmall!.copyWith(fontWeight: FontWeight.normal),
              hasWallpaper: hasBackground,
              fallbackColor: fallbackColor,
            ),
            overflow: TextOverflow.visible,
            softWrap: false,
            maxLines: oneLine ? 1 : 2,
          ),
        ),
      );
    });
  }
}
