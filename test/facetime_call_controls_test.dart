import 'package:bluebubbles/app/components/facetime/call_controls.dart';
import 'package:bluebubbles/app/components/facetime/facetime_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FaceTime tokens', () {
    test('new palette, dims, and motion tokens match M3E spec', () {
      expect(FaceTimePalette.accept, const Color(0xFF1D873B));
      expect(FaceTimePalette.decline, const Color(0xFFD93E36));
      expect(FaceTimePalette.engagedFill, Colors.white);
      expect(FaceTimePalette.engagedIcon, const Color(0xFF5F6368));
      expect(FaceTimePalette.speakerOutline, const Color(0xFF0842A0));
      expect(FaceTimePalette.scrim, const Color(0x99000000));

      expect(FaceTimeDims.dockRadius, 24.0);
      expect(FaceTimeDims.dockMaxWidth, 600.0);
      expect(FaceTimeDims.dockButtonHeight, 48.0);
      expect(FaceTimeDims.dockButtonMinWidth, 48.0);
      expect(FaceTimeDims.dockButtonMaxWidth, 64.0);
      expect(FaceTimeDims.dockGap, 8.0);
      expect(FaceTimeDims.dockPadH, 12.0);
      expect(FaceTimeDims.dockPadV, 12.0);
      expect(FaceTimeDims.dockMargin, 16.0);
      expect(FaceTimeDims.dockDividerH, 20.0);
      expect(FaceTimeDims.endPillWidth, 72.0);
      expect(FaceTimeDims.endPillWideWidth, 96.0);
      expect(FaceTimeDims.headerHeight, 48.0);
      expect(FaceTimeDims.headerTitleMaxWidth, 200.0);
      expect(FaceTimeDims.pipMin, 88.0);
      expect(FaceTimeDims.pipMax, 156.0);
      expect(FaceTimeDims.pipWebMax, 240.0);
      expect(FaceTimeDims.pipRadius, 12.0);
      expect(FaceTimeDims.pipInset, 12.0);
      expect(FaceTimeDims.puckSize, 72.0);
      expect(FaceTimeDims.puckIcon, 36.0);
      expect(FaceTimeDims.puckGap, 32.0);
      expect(FaceTimeDims.puckGapWide, 40.0);
      expect(FaceTimeDims.tileRadius, 12.0);
      expect(FaceTimeDims.compactBreak, 600.0);
      expect(FaceTimeDims.expandedBreak, 840.0);

      expect(FaceTimeMotion.emphasized, const Cubic(0.2, 0.0, 0.0, 1.0));
      expect(FaceTimeMotion.short, const Duration(milliseconds: 200));
      expect(FaceTimeMotion.morph, const Duration(milliseconds: 250));
      expect(FaceTimeMotion.medium, const Duration(milliseconds: 300));
      expect(FaceTimeMotion.chromeFade, const Duration(milliseconds: 300));
      expect(FaceTimeMotion.ring, const Duration(milliseconds: 2000));
      expect(FaceTimeMotion.autoHide, const Duration(seconds: 4));

      // Google Meet / Google Phone M3E tokens.
      expect(FaceTimePalette.m3Surface, const Color(0xFF131314));
      expect(FaceTimePalette.m3SurfaceContainer, const Color(0xFF1E1F20));
      expect(FaceTimePalette.m3SurfaceContainerHigh, const Color(0xFF282A2C));
      expect(FaceTimePalette.m3SurfaceContainerHighest, const Color(0xFF333537));
      expect(FaceTimePalette.m3SurfaceVariant, const Color(0xFF444746));
      expect(FaceTimePalette.m3OnSurface, const Color(0xFFE3E3E3));
      expect(FaceTimePalette.m3OnSurfaceVariant, const Color(0xFFC4C7C5));
      expect(FaceTimePalette.m3Primary, const Color(0xFFA8C7FA));
      expect(FaceTimePalette.m3OnPrimary, const Color(0xFF062E6F));
      expect(FaceTimePalette.m3MutedFill, const Color(0xFFF2B8B5));
      expect(FaceTimePalette.m3OnMutedFill, const Color(0xFF601410));
      expect(FaceTimePalette.m3EndCallRed, const Color(0xFFD93025));
      expect(FaceTimePalette.m3AcceptGreen, const Color(0xFF137333));
      expect(FaceTimePalette.m3Scrim, const Color(0x99000000));

      expect(FaceTimeDims.dockContainerRadius, 24.0);
      expect(FaceTimeDims.dockButtonMorphSelectedRadius, 16.0);
      expect(FaceTimeDims.phoneSheetTopRadius, 32.0);
      expect(FaceTimeDims.phoneToggleHeight, 68.0);
      expect(FaceTimeDims.phoneEndPillHeight, 72.0);
      expect(FaceTimeDims.pipCornerRadius, 24.0);
      expect(FaceTimeDims.pipActionButtonSize, 32.0);
      expect(FaceTimeDims.pipActionIconSize, 18.0);
      expect(FaceTimeDims.swipeTrackHeight, 96.0);
      expect(FaceTimeDims.swipeTrackMaxWidth, 344.0);
    });

    testWidgets('FaceTimeMotion.of respects MediaQuery.disableAnimations', (tester) async {
      late Duration normalDuration;
      late Duration reducedDuration;

      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              MediaQuery(
                data: const MediaQueryData(disableAnimations: false),
                child: Builder(
                  builder: (context) {
                    normalDuration = FaceTimeMotion.of(context, FaceTimeMotion.medium);
                    return const SizedBox.shrink();
                  },
                ),
              ),
              MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: Builder(
                  builder: (context) {
                    reducedDuration = FaceTimeMotion.of(context, FaceTimeMotion.medium);
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ],
          ),
        ),
      );

      expect(normalDuration, FaceTimeMotion.medium);
      expect(reducedDuration, Duration.zero);
    });
  });

  group('faceTimeSnapCorner', () {
    const area = Size(390, 844);
    const tile = Size(109, 145);
    const avoid = EdgeInsets.only(top: 72, bottom: 96);

    test('snaps to all 4 corners inside area deflated by avoid + pipInset', () {
      const inset = FaceTimeDims.pipInset; // 12
      final minX = avoid.left + inset; // 12
      final maxX = area.width - avoid.right - inset - tile.width; // 390 - 12 - 109 = 269
      final minY = avoid.top + inset; // 84
      final maxY = area.height - avoid.bottom - inset - tile.height; // 844 - 96 - 12 - 145 = 591

      expect(faceTimeSnapCorner(const Offset(40, 100), area, tile, avoid), Offset(minX, minY));
      expect(faceTimeSnapCorner(const Offset(350, 100), area, tile, avoid), Offset(maxX, minY));
      expect(faceTimeSnapCorner(const Offset(40, 700), area, tile, avoid), Offset(minX, maxY));
      expect(faceTimeSnapCorner(const Offset(350, 700), area, tile, avoid), Offset(maxX, maxY));
    });

    test('uses tile center symmetrically for quadrant tie-breaking', () {
      const symArea = Size(400, 800);
      const symTile = Size(100, 133);

      // Slightly left & above center -> top-left
      expect(
        faceTimeSnapCorner(const Offset(199, 399), symArea, symTile, EdgeInsets.zero),
        const Offset(12, 12),
      );
      // Slightly right & below center -> bottom-right
      expect(
        faceTimeSnapCorner(const Offset(201, 401), symArea, symTile, EdgeInsets.zero),
        const Offset(400 - 12 - 100, 800 - 12 - 133),
      );
    });

    test('clamps safely without throwing when avoid exceeds available space', () {
      final result = faceTimeSnapCorner(
        const Offset(100, 100),
        const Size(120, 120),
        const Size(88, 117),
        const EdgeInsets.all(40),
      );
      expect(result.dx, inInclusiveRange(0.0, 32.0));
      expect(result.dy, inInclusiveRange(0.0, 3.0));
    });
  });

  group('Dock & header widgets', () {
    testWidgets('FaceTimeDockButton renders idle, engaged, disabled, dense, tooltip, and semantics',
        (tester) async {
      var taps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FaceTimeDockButton(
                    key: const Key('btn_idle'),
                    icon: Icons.mic_rounded,
                    label: 'Mute mic',
                    onPressed: () => taps++,
                  ),
                  const FaceTimeDockButton(
                    key: Key('btn_engaged'),
                    icon: Icons.mic_off_rounded,
                    label: 'Unmute mic',
                    engaged: true,
                  ),
                  FaceTimeDockButton(
                    key: const Key('btn_disabled'),
                    icon: Icons.flip_camera_android_rounded,
                    label: 'Flip camera',
                    enabled: false,
                    onPressed: () => taps++,
                  ),
                  const FaceTimeDockButton(
                    key: Key('btn_dense'),
                    icon: Icons.mic_rounded,
                    label: 'Dense mute',
                    dense: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final idleSize = tester.getSize(find.byKey(const Key('btn_idle')));
      expect(idleSize.width, inInclusiveRange(48, 64));
      expect(idleSize.height, 48);

      final denseSize = tester.getSize(find.byKey(const Key('btn_dense')));
      expect(denseSize.height, 40);
      expect(denseSize.width, greaterThanOrEqualTo(44));

      // Verify idle vs engaged colors.
      final idleBox = tester
          .widget<AnimatedContainer>(
            find.descendant(of: find.byKey(const Key('btn_idle')), matching: find.byType(AnimatedContainer)),
          )
          .decoration! as BoxDecoration;
      expect(idleBox.color, FaceTimePalette.darkElevated);

      final engagedBox = tester
          .widget<AnimatedContainer>(
            find.descendant(of: find.byKey(const Key('btn_engaged')), matching: find.byType(AnimatedContainer)),
          )
          .decoration! as BoxDecoration;
      expect(engagedBox.color, FaceTimePalette.engagedFill);

      final engagedIcon = tester.widget<Icon>(
        find.descendant(of: find.byKey(const Key('btn_engaged')), matching: find.byType(Icon)),
      );
      expect(engagedIcon.color, FaceTimePalette.engagedIcon);

      // Verify disabled opacity and tap suppression.
      final disabledOpacity = tester.widget<Opacity>(
        find.descendant(of: find.byKey(const Key('btn_disabled')), matching: find.byType(Opacity)),
      );
      expect(disabledOpacity.opacity, 0.38);

      await tester.tap(find.bySemanticsLabel('Mute mic'));
      await tester.pumpAndSettle();
      expect(taps, 1);

      await tester.tap(find.bySemanticsLabel('Flip camera'));
      await tester.pumpAndSettle();
      expect(taps, 1);

      expect(find.byTooltip('Mute mic'), findsOneWidget);
      expect(find.byTooltip('Unmute mic'), findsOneWidget);
    });

    testWidgets('FaceTimeEndCallPill respects wide, dense, and End call semantics', (tester) async {
      var ended = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                FaceTimeEndCallPill(key: const Key('end_std'), onPressed: () => ended++),
                FaceTimeEndCallPill(key: const Key('end_wide'), wide: true, onPressed: () {}),
                FaceTimeEndCallPill(key: const Key('end_dense'), dense: true, onPressed: () {}),
              ],
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(const Key('end_std'))), const Size(72, 48));
      expect(tester.getSize(find.byKey(const Key('end_wide'))), const Size(96, 48));
      expect(tester.getSize(find.byKey(const Key('end_dense'))).height, 40);

      await tester.tap(find.byKey(const Key('end_std')));
      await tester.pumpAndSettle();
      expect(ended, 1);
      expect(find.bySemanticsLabel('End call'), findsNWidgets(3));
    });

    testWidgets('FaceTimeControlDock fits 320px width and caps at 600px on wide viewports', (tester) async {
      Widget buildDock() {
        return FaceTimeControlDock(
          translucent: true,
          controls: const [
            FaceTimeDockButton(icon: Icons.mic_rounded, label: 'Mute'),
            FaceTimeDockButton(icon: Icons.videocam_rounded, label: 'Camera'),
            FaceTimeDockButton(icon: Icons.flip_camera_android_rounded, label: 'Flip'),
            FaceTimeDockButton(icon: Icons.volume_up_rounded, label: 'Speaker'),
          ],
          endCall: FaceTimeEndCallPill(onPressed: () {}),
        );
      }

      // 320px narrow screen: zero overflow, endCall stays visible.
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: buildDock()))));
      await tester.pump();
      expect(tester.takeException(), isNull);

      final narrowDockRect = tester.getRect(find.byType(FaceTimeControlDock));
      expect(narrowDockRect.left, greaterThanOrEqualTo(0));
      expect(narrowDockRect.right, lessThanOrEqualTo(320));
      expect(tester.getSize(find.byType(FaceTimeEndCallPill)).width, 72);

      // 1440px wide screen: capped <= 600px.
      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: buildDock()))));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(FaceTimeControlDock)).width, lessThanOrEqualTo(600));
    });

    testWidgets('FaceTimeHeaderPill & FaceTimeStatusText handle 40-char name at text scale 2.0',
        (tester) async {
      const longName = 'Alexandria Montgomery-Fitzwilliam III Jr';

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: Scaffold(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FaceTimeHeaderPill(
                    leading: IconButton(
                      onPressed: () {},
                      icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white),
                    ),
                    title: longName,
                    subtitle: '02:14',
                    trailing: [
                      IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.open_in_new_rounded, color: Colors.white),
                      ),
                    ],
                  ),
                  const FaceTimeStatusText('Connected', duration: '02:14', muted: true),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      expect(find.text(longName), findsOneWidget);
      expect(find.text('02:14'), findsOneWidget);
      expect(find.text('Connected · 02:14'), findsOneWidget);
      expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
    });

    testWidgets('FaceTimeDockButton and FaceTimeEndCallPill use Duration.zero under reduced motion',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: Row(
                children: [
                  const FaceTimeDockButton(icon: Icons.mic_rounded, label: 'Mute'),
                  FaceTimeEndCallPill(onPressed: () {}),
                ],
              ),
            ),
          ),
        ),
      );

      final scales = tester.widgetList<AnimatedScale>(find.byType(AnimatedScale)).toList();
      expect(scales, hasLength(2));
      for (final s in scales) {
        expect(s.duration, Duration.zero);
        expect(s.scale, 1.0);
      }

      final container = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
      expect(container.duration, Duration.zero);
    });

    testWidgets('FaceTimeStatusText adapts color between dark and light surfaces', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Material(
                  color: FaceTimePalette.darkSurface,
                  child: FaceTimeStatusText('Dark', duration: '00:05'),
                ),
                Material(
                  color: Colors.white,
                  child: FaceTimeStatusText('Light', duration: '00:05'),
                ),
              ],
            ),
          ),
        ),
      );

      final darkText = tester.widget<Text>(find.text('Dark · 00:05'));
      final lightText = tester.widget<Text>(find.text('Light · 00:05'));
      expect(darkText.style?.color, FaceTimePalette.secondaryText);
      expect(lightText.style?.color, isNot(FaceTimePalette.secondaryText));
    });
  });

  group('M3E FaceTime controls', () {
    testWidgets('FaceTimeDockButton morphs radius 24->16, supports tones, caret, and custom size',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                FaceTimeDockButton(
                  key: Key('tone_neutral'),
                  icon: Icons.mic_rounded,
                  label: 'Mute',
                  tone: FaceTimeDockTone.neutral,
                ),
                FaceTimeDockButton(
                  key: Key('tone_muted'),
                  icon: Icons.mic_off_rounded,
                  label: 'Unmute',
                  engaged: true,
                  tone: FaceTimeDockTone.mutedAlert,
                ),
                FaceTimeDockButton(
                  key: Key('tone_primary'),
                  icon: Icons.volume_up_rounded,
                  label: 'Audio',
                  engaged: true,
                  tone: FaceTimeDockTone.activePrimary,
                  showExpandCaret: true,
                  width: 60,
                  height: 52,
                ),
                FaceTimeDockButton(
                  key: Key('tone_hc'),
                  icon: Icons.dialpad_rounded,
                  label: 'Keypad',
                  engaged: true,
                  tone: FaceTimeDockTone.activeHighContrast,
                ),
              ],
            ),
          ),
        ),
      );

      final neutralBox = tester
          .widget<AnimatedContainer>(
            find.descendant(of: find.byKey(const Key('tone_neutral')), matching: find.byType(AnimatedContainer)),
          );
      expect(neutralBox.duration, FaceTimeMotion.morph);
      expect((neutralBox.decoration! as BoxDecoration).borderRadius, BorderRadius.circular(24));
      expect((neutralBox.decoration! as BoxDecoration).color, FaceTimePalette.m3SurfaceContainerHighest);

      final mutedBox = tester
          .widget<AnimatedContainer>(
            find.descendant(of: find.byKey(const Key('tone_muted')), matching: find.byType(AnimatedContainer)),
          )
          .decoration! as BoxDecoration;
      expect(mutedBox.borderRadius, BorderRadius.circular(16));
      expect(mutedBox.color, FaceTimePalette.m3MutedFill);

      expect(tester.getSize(find.byKey(const Key('tone_primary'))), const Size(60, 52));
      expect(
        find.descendant(
          of: find.byKey(const Key('tone_primary')),
          matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
        ),
        findsOneWidget,
      );

      final hcBox = tester
          .widget<AnimatedContainer>(
            find.descendant(of: find.byKey(const Key('tone_hc')), matching: find.byType(AnimatedContainer)),
          )
          .decoration! as BoxDecoration;
      expect(hcBox.color, FaceTimePalette.m3OnSurface);
    });

    testWidgets('FaceTimeControlDock keeps width invariant when toggling engaged', (tester) async {
      var engaged = false;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              return Scaffold(
                body: Center(
                  child: FaceTimeControlDock(
                    controls: [
                      FaceTimeDockButton(
                        key: const Key('toggle_btn'),
                        icon: Icons.videocam_rounded,
                        label: 'Camera',
                        engaged: engaged,
                        tone: engaged ? FaceTimeDockTone.mutedAlert : FaceTimeDockTone.neutral,
                        onPressed: () => setState(() => engaged = !engaged),
                      ),
                      const FaceTimeDockButton(
                        icon: Icons.mic_rounded,
                        label: 'Mic',
                        tone: FaceTimeDockTone.neutral,
                      ),
                    ],
                    endCall: FaceTimeEndCallPill(onPressed: () {}),
                  ),
                ),
              );
            },
          ),
        ),
      );

      final initialWidth = tester.getSize(find.byType(FaceTimeControlDock)).width;
      await tester.tap(find.byKey(const Key('toggle_btn')));
      await tester.pumpAndSettle();
      final toggledWidth = tester.getSize(find.byType(FaceTimeControlDock)).width;
      expect(toggledWidth, initialWidth);
    });

    testWidgets('FaceTimePhoneControlSheet renders 4 morphing toggles and stadium End Call pill',
        (tester) async {
      var muted = false;
      var ended = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              return Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: FaceTimePhoneControlSheet(
                    compact: false,
                    landscape: false,
                    items: [
                      FaceTimePhoneControlItem(
                        key: const Key('phone_mute'),
                        icon: muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                        label: 'Mute',
                        selected: muted,
                        onPressed: () => setState(() => muted = !muted),
                      ),
                      const FaceTimePhoneControlItem(
                        icon: Icons.dialpad_rounded,
                        label: 'Keypad',
                      ),
                      const FaceTimePhoneControlItem(
                        icon: Icons.volume_up_rounded,
                        label: 'Speaker',
                        showExpandCaret: true,
                      ),
                      const FaceTimePhoneControlItem(
                        icon: Icons.more_horiz_rounded,
                        label: 'More',
                      ),
                    ],
                    onEndCall: () => ended++,
                  ),
                ),
              );
            },
          ),
        ),
      );

      final muteBox = tester
          .widget<AnimatedContainer>(
            find.descendant(of: find.byKey(const Key('phone_mute')), matching: find.byType(AnimatedContainer)),
          )
          .decoration! as BoxDecoration;
      expect(muteBox.borderRadius, BorderRadius.circular(34.0));
      expect(tester.getSize(find.bySemanticsLabel('End call')).height, 72.0);

      await tester.tap(find.byKey(const Key('phone_mute')));
      await tester.pumpAndSettle();

      final muteBoxSelected = tester
          .widget<AnimatedContainer>(
            find.descendant(of: find.byKey(const Key('phone_mute')), matching: find.byType(AnimatedContainer)),
          )
          .decoration! as BoxDecoration;
      expect(muteBoxSelected.borderRadius, BorderRadius.circular(17.0));
      expect(muteBoxSelected.color, FaceTimePalette.m3OnSurface);

      await tester.tap(find.bySemanticsLabel('End call'));
      await tester.pumpAndSettle();
      expect(ended, 1);
    });

    testWidgets('FaceTimeSwipeAnswerPill supports drag right/left, bounce-back, tap fallback, and narrow fallback',
        (tester) async {
      var accepted = 0;
      var declined = 0;

      Widget buildPill({bool accessible = false, double width = 360}) {
        return MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              disableAnimations: true,
              accessibleNavigation: accessible,
            ),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  child: FaceTimeSwipeAnswerPill(
                    key: UniqueKey(),
                    onAccept: () => accepted++,
                    onDecline: () => declined++,
                  ),
                ),
              ),
            ),
          ),
        );
      }

      // 1. Partial drag bounces back without committing.
      await tester.pumpWidget(buildPill());
      await tester.drag(find.byType(FaceTimeSwipeAnswerPill), const Offset(30, 0));
      await tester.pumpAndSettle();
      expect(accepted, 0);
      expect(declined, 0);

      // 2. Full drag right -> Accept.
      await tester.drag(find.byType(FaceTimeSwipeAnswerPill), const Offset(220, 0));
      await tester.pumpAndSettle();
      expect(accepted, 1);
      expect(declined, 0);

      // 3. Full drag left -> Decline.
      await tester.pumpWidget(buildPill());
      await tester.drag(find.byType(FaceTimeSwipeAnswerPill), const Offset(-220, 0));
      await tester.pumpAndSettle();
      expect(accepted, 1);
      expect(declined, 1);

      // 4. Direct tap on Accept / Decline labels.
      await tester.pumpWidget(buildPill());
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(accepted, 2);

      await tester.pumpWidget(buildPill());
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      expect(declined, 2);

      // 5. Narrow width (<260dp) falls back to 72dp dual pucks.
      await tester.pumpWidget(buildPill(width: 240));
      await tester.pumpAndSettle();
      expect(find.text('Accept'), findsNothing);
      expect(tester.getSize(find.bySemanticsLabel('Accept')), const Size(72, 72));
      expect(tester.getSize(find.bySemanticsLabel('Decline')), const Size(72, 72));
      await tester.tap(find.bySemanticsLabel('Accept'));
      await tester.pumpAndSettle();
      expect(accepted, 3);
    });
  });
}
