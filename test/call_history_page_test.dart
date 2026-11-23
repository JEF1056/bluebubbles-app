import 'package:bluebubbles/app/layouts/call_history/call_history_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CallLogEntry & helpers', () {
    test('fromJson parses fields and falls back participants to address', () {
      final entry = CallLogEntry.fromJson({
        'id': 'call-1',
        'date': 1700000000000,
        'duration': 65,
        'direction': 'missed',
        'service': 'facetime_video',
        'isVideo': true,
        'address': '+15551234567',
        'name': 'Maya Lin',
        'participants': <String>[],
        'read': false,
      });

      expect(entry.id, 'call-1');
      expect(entry.date.millisecondsSinceEpoch, 1700000000000);
      expect(entry.duration, 65);
      expect(entry.isMissed, isTrue);
      expect(entry.isVideo, isTrue);
      expect(entry.participants, ['+15551234567']);
      expect(entry.read, isFalse);
    });

    test('bucketCallDate groups Today, Yesterday, and Earlier on local date', () {
      final now = DateTime(2026, 11, 22, 14, 30);
      expect(bucketCallDate(DateTime(2026, 11, 22, 0, 5), now: now), CallDayBucket.today);
      expect(bucketCallDate(DateTime(2026, 11, 21, 23, 55), now: now), CallDayBucket.yesterday);
      expect(bucketCallDate(DateTime(2026, 11, 19, 12, 0), now: now), CallDayBucket.earlier);
    });

    test('formatCallDuration formats m:ss', () {
      expect(formatCallDuration(0), '0:00');
      expect(formatCallDuration(5), '0:05');
      expect(formatCallDuration(65), '1:05');
      expect(formatCallDuration(754), '12:34');
    });
  });

  group('CallHistoryPage widget', () {
    List<CallLogEntry> sampleEntries() {
      final now = DateTime.now();
      return [
        CallLogEntry(
          id: 'today-1',
          date: now.subtract(const Duration(minutes: 10)),
          duration: 125,
          direction: 'outgoing',
          service: 'facetime_video',
          isVideo: true,
          address: '+15550001111',
          name: 'Alex Rivera',
          participants: const ['+15550001111'],
        ),
        CallLogEntry(
          id: 'yesterday-1',
          date: DateTime(now.year, now.month, now.day - 1, 16, 0),
          duration: 0,
          direction: 'missed',
          service: 'facetime_audio',
          isVideo: false,
          address: '+15550002222',
          name: 'Jordan Vance',
          participants: const ['+15550002222'],
        ),
        CallLogEntry(
          id: 'earlier-1',
          date: DateTime(now.year, now.month, now.day - 4, 11, 0),
          duration: 42,
          direction: 'incoming',
          service: 'phone',
          isVideo: false,
          address: '+15550003333',
          name: 'Sam Patel',
          participants: const ['+15550003333', '+15550004444'],
        ),
      ];
    }

    testWidgets('renders section headers, filters Missed on server, and expands row on tap', (tester) async {
      final calls = sampleEntries();
      final recordedMissedFlags = <bool>[];

      await tester.pumpWidget(
        MaterialApp(
          home: CallHistoryPage(
            loader: ({required limit, required offset, required missedOnly}) async {
              recordedMissedFlags.add(missedOnly);
              final filtered = missedOnly ? calls.where((e) => e.isMissed).toList() : calls;
              return CallHistoryResult(entries: filtered, available: true, hasMore: false);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Calls'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Earlier'), findsOneWidget);
      expect(find.text('Alex Rivera'), findsOneWidget);
      expect(find.text('Jordan Vance'), findsOneWidget);

      // Tap row to expand details and show Message action.
      expect(find.text('Message'), findsNothing);
      await tester.tap(find.text('Alex Rivera'));
      await tester.pumpAndSettle();
      expect(find.text('Message'), findsOneWidget);

      // Tap Missed filter pill -> reloads with missedOnly: true.
      await tester.tap(find.text('Missed'));
      await tester.pumpAndSettle();
      expect(recordedMissedFlags, [false, true]);
      expect(find.text('Alex Rivera'), findsNothing);
      expect(find.text('Jordan Vance'), findsOneWidget);
    });

    testWidgets('renders available: false Full Disk Access card', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CallHistoryPage(
            loader: ({required limit, required offset, required missedOnly}) async => const CallHistoryResult(
              entries: [],
              available: false,
              reason: 'SQLITE_CANTOPEN',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text("Mac can't read call history — grant Full Disk Access to BlueBubbles Server"),
        findsOneWidget,
      );
      expect(find.text('SQLITE_CANTOPEN'), findsOneWidget);
    });

    testWidgets('renders Create Link button in header and invokes onCreateLink', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: CallHistoryPage(
            loader: ({required limit, required offset, required missedOnly}) async => const CallHistoryResult(
              entries: [],
              available: true,
              hasMore: false,
            ),
            onCreateLink: () => tapped = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Create Link'), findsOneWidget);
      await tester.tap(find.text('Create Link'));
      await tester.pump();
      expect(tapped, isTrue);
    });
  });
}
