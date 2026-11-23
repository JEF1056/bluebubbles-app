import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show PointerDeviceKind;

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/contact_card.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/location_card.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/other_file.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

class _FakeSettingsService extends SettingsService {}

class _FakeThemesService extends ThemesService {}

void main() {
  setUpAll(() {
    if (!GetIt.I.isRegistered<SettingsService>()) {
      GetIt.I.registerSingleton<SettingsService>(_FakeSettingsService()..settings = Settings());
    }
    if (!GetIt.I.isRegistered<ThemesService>()) {
      GetIt.I.registerSingleton<ThemesService>(_FakeThemesService());
    }
    if (!GetIt.I.isRegistered<AttachmentsService>()) {
      GetIt.I.registerSingleton<AttachmentsService>(AttachmentsService());
    }
  });

  testWidgets('ContactCard renders vCard details and tap opens a sheet (not a Dialog)', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const vcard = 'BEGIN:VCARD\n'
        'VERSION:3.0\n'
        'N:Doe;Jane;;;\n'
        'FN:Jane Doe\n'
        'TEL;TYPE=CELL:+15551234567\n'
        'EMAIL;TYPE=HOME:jane@example.com\n'
        'END:VCARD\n';

    final file = PlatformFile(
      name: 'jane.vcf',
      size: vcard.length,
      bytes: Uint8List.fromList(utf8.encode(vcard)),
    );
    final attachment = Attachment(
      guid: 'att-vcard-1',
      mimeType: 'text/vcard',
      transferName: 'jane.vcf',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: ContactCard(file: file, attachment: attachment),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.text('+15551234567'), findsOneWidget);

    await tester.tap(find.byType(ContactCard));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
      find.descendant(of: find.byType(BottomSheet), matching: find.text('jane@example.com')),
      findsOneWidget,
    );
    expect(find.text('Download .vcf'), findsOneWidget);
  });

  testWidgets('LocationCard renders parsed coordinates from vlocation file', (tester) async {
    const vlocation = 'BEGIN:VCARD\n'
        'VERSION:3.0\n'
        'N:;Current Location;;;\n'
        'FN:Current Location\n'
        'URL;type=pref:https://maps.apple.com/?ll=37.42199,-122.08405&q=37.42199,-122.08405\n'
        'END:VCARD\n';

    final file = PlatformFile(
      name: 'loc.vcf',
      size: vlocation.length,
      bytes: Uint8List.fromList(utf8.encode(vlocation)),
    );
    final attachment = Attachment(
      guid: 'att-loc-1',
      mimeType: 'text/x-vlocation',
      uti: 'public.vlocation',
      transferName: 'loc.vcf',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: LocationCard(
              file: file,
              attachment: attachment,
              messageDate: DateTime(2026, 11, 22),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Location'), findsOneWidget);
    expect(find.text('37.42199, -122.08405'), findsOneWidget);
    expect(find.byIcon(Icons.location_on_rounded), findsOneWidget);
  });

  testWidgets('OtherFile shows download IconButton on web hover', (tester) async {
    final file = PlatformFile(
      name: 'report.pdf',
      size: 2048,
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    final attachment = Attachment(
      guid: 'att-file-1',
      mimeType: 'application/pdf',
      transferName: 'report.pdf',
      totalBytes: 2048,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: OtherFile(
              file: file,
              attachment: attachment,
              isWebOverride: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsNothing);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(OtherFile)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
  });
}
