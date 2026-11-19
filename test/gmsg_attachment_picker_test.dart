import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/gmsg_camera_gallery_sheet.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/text_field_attachment_picker.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  testWidgets('GmsgAttachmentDrawer renders 4-col grid, toggles chevron, and fires action taps', (tester) async {
    final tapped = <String>[];
    bool expanded = false;

    final actions = [
      GmsgAttachmentAction(
        label: 'Gallery',
        icon: Icons.photo_library_outlined,
        onTap: () => tapped.add('Gallery'),
      ),
      GmsgAttachmentAction(
        label: 'Camera',
        icon: Icons.photo_camera_outlined,
        onTap: () => tapped.add('Camera'),
      ),
      GmsgAttachmentAction(
        label: 'GIFs',
        icon: Icons.gif_box_outlined,
        onTap: () => tapped.add('GIFs'),
      ),
      GmsgAttachmentAction(
        label: 'Files',
        icon: Icons.folder_outlined,
        onTap: () => tapped.add('Files'),
      ),
      GmsgAttachmentAction(
        label: 'Location',
        icon: Icons.location_on_outlined,
        onTap: () => tapped.add('Location'),
      ),
      GmsgAttachmentAction(
        label: 'Schedule Send',
        icon: Icons.schedule_outlined,
        onTap: () => tapped.add('Schedule Send'),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Align(
              alignment: Alignment.bottomCenter,
              child: GmsgAttachmentDrawer(
                actions: actions,
                expanded: expanded,
                onExpandedChanged: (v) => setState(() => expanded = v),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
    expect(find.text('Gallery'), findsOneWidget);
    expect(find.text('Schedule Send'), findsOneWidget);

    // First 4 items share the first row (equal top Y); 5th wraps to row 2.
    final galleryTop = tester.getTopLeft(find.text('Gallery')).dy;
    final filesTop = tester.getTopLeft(find.text('Files')).dy;
    final locationTop = tester.getTopLeft(find.text('Location')).dy;
    expect(filesTop, closeTo(galleryTop, 0.5));
    expect(locationTop, greaterThan(galleryTop));

    final collapsedHeight = tester.getSize(find.byType(GmsgAttachmentDrawer)).height;

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up_rounded));
    await tester.pumpAndSettle();

    expect(expanded, isTrue);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
    expect(tester.getSize(find.byType(GmsgAttachmentDrawer)).height, greaterThan(collapsedHeight));

    await tester.tap(find.text('GIFs'));
    await tester.pump();
    expect(tapped, ['GIFs']);
  });

  testWidgets('GmsgCameraGallerySheet insets top controls below status bar inside modal sheet', (tester) async {
    final chat = Chat(guid: 'iMessage;-;+15550001234');
    final controller = ConversationViewController(chat);
    addTearDown(() {
      if (Get.isRegistered<ConversationViewController>(tag: chat.guid)) {
        Get.delete<ConversationViewController>(tag: chat.guid, force: true);
      }
      controller.dispose();
    });

    final composerFocus = FocusNode();
    addTearDown(composerFocus.dispose);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(412, 915),
          padding: EdgeInsets.only(top: 48),
          viewPadding: EdgeInsets.only(top: 48),
        ),
        child: GetMaterialApp(
          useInheritedMediaQuery: true,
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            appBar: AppBar(title: const Text('Chat')),
            body: Builder(
              builder: (context) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextField(focusNode: composerFocus),
                  ElevatedButton(
                    onPressed: () => showGmsgCameraGallerySheet(context, controller),
                    child: const Text('Open Camera'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    composerFocus.requestFocus();
    await tester.pump();
    expect(composerFocus.hasFocus, isTrue);

    await tester.tap(find.text('Open Camera'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(composerFocus.hasFocus, isFalse);

    final closeFinder = find.byIcon(Icons.close_rounded);
    expect(closeFinder, findsOneWidget);
    // ModalBottomSheetRoute strips top MediaQuery padding inside its builder,
    // yet the Close button must still sit below the 48px status bar (top >= 48 + 8).
    expect(tester.getTopLeft(closeFinder).dy, greaterThanOrEqualTo(56.0));
    final scrimFinder = find.byWidgetPredicate(
      (w) => w is DecoratedBox && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).gradient is LinearGradient,
    );
    expect(scrimFinder, findsOneWidget);
    expect(tester.getSize(scrimFinder).height, 104.0);
  });

  testWidgets('GmsgCameraGallerySheet.resolveTopInset falls back when MediaQuery top padding is stripped',
      (tester) async {
    double? resolvedWithCaller;
    double? resolvedWithLocal;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(top: 36)),
          child: Builder(
            builder: (context) {
              resolvedWithLocal = GmsgCameraGallerySheet.resolveTopInset(context, 48);
              return MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: Builder(
                  builder: (strippedContext) {
                    resolvedWithCaller = GmsgCameraGallerySheet.resolveTopInset(strippedContext, 48);
                    return const SizedBox.shrink();
                  },
                ),
              );
            },
          ),
        ),
      ),
    );

    expect(resolvedWithLocal, 36.0);
    expect(resolvedWithCaller, 48.0);
  });
}
