import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

class _TimestampParts {
  final String? date;
  final String time;
  const _TimestampParts({this.date, required this.time});
}

class TimestampSeparator extends StatelessWidget {
  const TimestampSeparator({
    super.key,
    required this.olderMessage,
  });
  final Message? olderMessage;

  static ({String date, String time}) formatMaterialParts(
    DateTime time, {
    DateTime? now,
    bool use24Hr = false,
  }) {
    final ref = now ?? DateTime.now();
    final local = time.toLocal();
    final today = DateTime(ref.year, ref.month, ref.day);
    final day = DateTime(local.year, local.month, local.day);
    final diffDays = today.difference(day).inDays;
    final date = diffDays == 0
        ? "Today"
        : diffDays == 1
            ? "Yesterday"
            : (local.year == ref.year
                ? DateFormat('EEEE, MMM d').format(local)
                : DateFormat('EEEE, MMM d, y').format(local));
    final timeStr = use24Hr ? DateFormat.Hm().format(local) : DateFormat.jm().format(local);
    return (date: date, time: timeStr);
  }

  bool withinTimeThreshold(Message first, Message? second) {
    if (second == null) return false;
    return second.dateCreated!.difference(first.dateCreated!).inMinutes.abs() > 30;
  }

  _TimestampParts? _buildTimeStamp(Message message) {
    if (SettingsSvc.settings.skin.value == Skins.Samsung &&
        message.dateCreated?.day != olderMessage?.dateCreated?.day) {
      return _TimestampParts(time: buildSeparatorDateSamsung(message.dateCreated!));
    } else if (SettingsSvc.settings.skin.value != Skins.Samsung && withinTimeThreshold(message, olderMessage)) {
      final time = message.dateCreated!;
      if (SettingsSvc.settings.skin.value == Skins.iOS) {
        return _TimestampParts(date: time.isToday() ? "Today" : buildDate(time), time: buildTime(time));
      } else {
        final parts = formatMaterialParts(time, use24Hr: SettingsSvc.settings.use24HrFormat.value);
        return _TimestampParts(date: parts.date, time: parts.time);
      }
    } else {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = MessageStateScope.messageOf(context);
    final timestamp = _buildTimeStamp(message);
    final hasBackground = ChatStateScope.maybeOf(context)?.hasCustomWallpaper ?? false;
    final isMaterial = SettingsSvc.settings.skin.value == Skins.Material;

    if (timestamp == null) return const SizedBox.shrink();

    final textColor =
        hasBackground || isMaterial ? context.theme.colorScheme.onSurfaceVariant : context.theme.colorScheme.outline;
    final baseStyle = (isMaterial ? context.theme.textTheme.bodySmall! : context.theme.textTheme.labelSmall!)
        .copyWith(color: textColor, fontWeight: FontWeight.normal);

    final richText = RichText(
      text: TextSpan(
        style: baseStyle,
        children: [
          if (timestamp.date != null)
            TextSpan(
              text: timestamp.date!,
              style: baseStyle.copyWith(fontWeight: isMaterial ? FontWeight.w500 : FontWeight.w600),
            ),
          TextSpan(
            text: timestamp.date != null ? (isMaterial ? " · ${timestamp.time}" : " ${timestamp.time}") : timestamp.time,
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.all(14.0),
      child: hasBackground
          ? Center(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
                decoration: BoxDecoration(
                  color: context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: richText,
              ),
            )
          : isMaterial
              ? Center(child: richText)
              : richText,
    );
  }
}
