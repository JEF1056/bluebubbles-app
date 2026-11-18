import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/message_timestamp.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/timestamp_separator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

void main() {
  group('TimestampSeparator.formatMaterialParts', () {
    final now = DateTime(2026, 11, 18, 15, 45);

    test('formats today and yesterday labels cleanly', () {
      final today = TimestampSeparator.formatMaterialParts(
        DateTime(2026, 11, 18, 15, 40),
        now: now,
      );
      expect(today.date, 'Today');
      expect(today.time, DateFormat.jm().format(DateTime(2026, 11, 18, 15, 40)));

      final yesterday = TimestampSeparator.formatMaterialParts(
        DateTime(2026, 11, 17, 9, 5),
        now: now,
        use24Hr: true,
      );
      expect(yesterday.date, 'Yesterday');
      expect(yesterday.time, DateFormat.Hm().format(DateTime(2026, 11, 17, 9, 5)));
    });

    test('formats same-year and prior-year dates with full weekday and year only when needed', () {
      final sameYear = DateTime(2026, 10, 4, 11, 20);
      expect(
        TimestampSeparator.formatMaterialParts(sameYear, now: now).date,
        DateFormat('EEEE, MMM d').format(sameYear),
      );

      final priorYear = DateTime(2025, 10, 4, 11, 20);
      expect(
        TimestampSeparator.formatMaterialParts(priorYear, now: now).date,
        DateFormat('EEEE, MMM d, y').format(priorYear),
      );
    });
  });

  group('MessageTimestamp.formatMaterialTimestamp', () {
    final now = DateTime(2026, 11, 18, 15, 45);

    test('renders single-line time for messages sent today', () {
      final recent = DateTime(2026, 11, 18, 15, 44);
      final formatted = MessageTimestamp.formatMaterialTimestamp(recent, now: now);
      expect(formatted.contains('\n'), isFalse);
      expect(formatted.trim(), DateFormat.jm().format(recent));
    });

    test('renders short day/date on line 1 and time on line 2 for older messages', () {
      final threeDaysAgo = DateTime(2026, 11, 15, 8, 15);
      final formattedRecentDay = MessageTimestamp.formatMaterialTimestamp(threeDaysAgo, now: now);
      expect(
        formattedRecentDay,
        '   ${DateFormat('EEE').format(threeDaysAgo)}\n   ${DateFormat.jm().format(threeDaysAgo)}',
      );

      final sevenDaysAgo = DateTime(2026, 11, 11, 20, 0);
      expect(
        MessageTimestamp.formatMaterialTimestamp(sevenDaysAgo, now: now),
        '   ${DateFormat.MMMd().format(sevenDaysAgo)}\n   ${DateFormat.jm().format(sevenDaysAgo)}',
      );

      final olderThisYear = DateTime(2026, 10, 1, 20, 5);
      final formattedOlder = MessageTimestamp.formatMaterialTimestamp(olderThisYear, now: now, use24Hr: true);
      expect(
        formattedOlder,
        '   ${DateFormat.MMMd().format(olderThisYear)}\n   ${DateFormat.Hm().format(olderThisYear)}',
      );
    });

    test('returns empty string for null or epoch timestamps', () {
      expect(MessageTimestamp.formatMaterialTimestamp(null, now: now), '');
      expect(
        MessageTimestamp.formatMaterialTimestamp(DateTime.fromMillisecondsSinceEpoch(0), now: now),
        '',
      );
    });
  });
}
