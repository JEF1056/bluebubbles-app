import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:clock/clock.dart';
import 'package:intl/intl.dart';

DateTime? parseDate(dynamic value) {
  if (value == null) return null;
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) return DateTime.tryParse(value);
  if (value is DateTime) return value;
  return null;
}

/// Returns the delay until the next relative-timestamp boundary ("Now" ->
/// "1 min" -> ... -> "59 min" -> absolute time), or `null` when [dateTime] is
/// already formatted as an absolute timestamp (or [skin] is [Skins.iOS]).
Duration? nextRelativeTimestampTickDelay(DateTime? dateTime, {DateTime? now, Skins? skin}) {
  if (dateTime == null || dateTime.millisecondsSinceEpoch == 0) return null;
  final activeSkin = skin ?? SettingsSvc.settings.skin.value;
  if (activeSkin == Skins.iOS) return null;
  final currentTime = (now ?? clock.now()).toLocal();
  final target = dateTime.toLocal();
  final diff = currentTime.difference(target);
  // Treat small clock skew / future timestamps as elapsed 0 ("Now"), ticking at target + 1 min.
  final minutes = diff.isNegative ? 0 : diff.inMinutes;
  if (minutes >= 60) return null;
  final nextBoundary = target.add(Duration(minutes: minutes + 1));
  final delay = nextBoundary.difference(currentTime);
  return delay > Duration.zero ? delay : const Duration(milliseconds: 1);
}

String buildDate(DateTime? dateTime, {DateTime? now}) {
  if (dateTime == null || dateTime.millisecondsSinceEpoch == 0) return "";
  final currentTime = (now ?? clock.now()).toLocal();
  final localDate = dateTime.toLocal();
  final diff = currentTime.difference(localDate);
  final minutes = diff.isNegative ? 0 : diff.inMinutes;
  final isSameDay =
      localDate.year == currentTime.year && localDate.month == currentTime.month && localDate.day == currentTime.day;
  final yesterday = currentTime.subtract(const Duration(days: 1));
  final isYesterday =
      localDate.year == yesterday.year && localDate.month == yesterday.month && localDate.day == yesterday.day;
  final skin = SettingsSvc.settings.skin.value;
  final String time =
      SettingsSvc.settings.use24HrFormat.value ? DateFormat.Hm().format(localDate) : DateFormat.jm().format(localDate);
  String date;
  if (skin != Skins.iOS && minutes == 0) {
    date = "Now";
  } else if (skin != Skins.iOS && minutes < 60) {
    date = "$minutes min";
  } else if (isSameDay) {
    date = time;
  } else if (skin == Skins.iOS && isYesterday) {
    date = "Yesterday";
  } else if (diff.inDays <= 7) {
    date = "${DateFormat(skin != Skins.iOS ? "EEE" : "EEEE").format(localDate)}${skin != Skins.iOS ? " $time" : ""}";
  } else if (skin == Skins.Material && diff.inDays <= 365) {
    date = "${DateFormat.MMMd().format(localDate)}, $time";
  } else if (skin == Skins.Samsung && currentTime.year == localDate.year) {
    date = DateFormat.MMMd().format(localDate);
  } else if (skin == Skins.Samsung && currentTime.year != localDate.year) {
    date = DateFormat.yMMMd().format(localDate);
  } else {
    date = DateFormat.yMd().format(localDate);
  }
  return date;
}

String buildChatListDateMaterial(DateTime? dateTime, {DateTime? now}) {
  if (dateTime == null || dateTime.millisecondsSinceEpoch == 0) return "";
  final currentTime = (now ?? clock.now()).toLocal();
  final localDate = dateTime.toLocal();
  final diff = currentTime.difference(localDate);
  final minutes = diff.isNegative ? 0 : diff.inMinutes;
  final skin = SettingsSvc.settings.skin.value;
  String date;
  if (minutes == 0) {
    date = "Now";
  } else if (minutes < 60) {
    date = "$minutes min";
  } else if (diff.inDays <= 7) {
    date = DateFormat("EEE").format(localDate);
  } else if (skin == Skins.Material && diff.inDays <= 365) {
    date = DateFormat.MMMd().format(localDate);
  } else if (skin == Skins.Samsung && currentTime.year == localDate.year) {
    date = DateFormat.MMMd().format(localDate);
  } else if (skin == Skins.Samsung && currentTime.year != localDate.year) {
    date = DateFormat.yMMMd().format(localDate);
  } else {
    date = DateFormat.yMd().format(localDate);
  }
  return date;
}

String buildSeparatorDateMaterial(DateTime dateTime) {
  return DateFormat.MMMEd().format(dateTime);
}

String buildSeparatorDateSamsung(DateTime dateTime) {
  return DateFormat.yMMMMEEEEd().format(dateTime);
}

String buildTime(DateTime? dateTime) {
  if (dateTime == null || dateTime.millisecondsSinceEpoch == 0) return "";
  String time =
      SettingsSvc.settings.use24HrFormat.value ? DateFormat.Hm().format(dateTime) : DateFormat.jm().format(dateTime);
  return time;
}

String buildFullDate(DateTime time, {bool includeTime = true, bool useTodayYesterday = true}) {
  if (time.millisecondsSinceEpoch == 0) return "";

  late String date;
  if (includeTime) {
    if (SettingsSvc.settings.use24HrFormat.value) {
      if (useTodayYesterday) {
        if (time.isToday()) {
          date = "Today, ${DateFormat.Hm().format(time)}";
        } else if (time.isYesterday()) {
          date = "Yesterday, ${DateFormat.Hm().format(time)}";
        } else {
          date = DateFormat.yMd().add_Hm().format(time);
        }
      } else {
        date = DateFormat.yMd().add_Hm().format(time);
      }
    } else {
      if (useTodayYesterday) {
        if (time.isToday()) {
          date = "Today, ${DateFormat.jm().format(time)}";
        } else if (time.isYesterday()) {
          date = "Yesterday, ${DateFormat.jm().format(time)}";
        } else {
          date = DateFormat.yMd().add_jm().format(time);
        }
      } else {
        date = DateFormat.yMd().add_jm().format(time);
      }
    }
  } else {
    if (useTodayYesterday) {
      if (time.isToday()) {
        date = "Today";
      } else if (time.isYesterday()) {
        date = "Yesterday";
      } else {
        date = DateFormat.yMd().format(time);
      }
    } else {
      date = DateFormat.yMd().format(time);
    }
  }

  return date;
}
