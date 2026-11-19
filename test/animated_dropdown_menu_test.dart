import 'dart:async';

import 'package:bluebubbles/app/components/animated_dropdown_menu.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_page.dart' deferred as findmy;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  testWidgets(
    'menuBuilder context stays mounted across deferred loadLibrary after hideMenu',
    (tester) async {
      Type? openedPageType;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AnimatedDropdownMenu(
                menuWidth: 200,
                trigger: (context, showMenu) => TextButton(
                  onPressed: showMenu,
                  child: const Text('Open'),
                ),
                menuBuilder: (menuContext, hideMenu) => SizedBox(
                  width: 200,
                  child: Material(
                    color: menuContext.theme.colorScheme.surfaceContainerHighest,
                    child: MenuItemRow(
                      icon: Icons.location_on_outlined,
                      label: 'Find My',
                      onTap: () => hideMenu().then((_) async {
                        await findmy.loadLibrary();
                        if (!menuContext.mounted) return;
                        openedPageType = findmy.FindMyPage;
                      }),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Find My'));
      await tester.pumpAndSettle();

      expect(openedPageType, isNotNull);
    },
  );

  testWidgets(
    'menuBuilder context becomes unmounted when anchor widget is disposed mid-action',
    (tester) async {
      var sawUnmounted = false;
      final pending = Completer<void>();
      final showHost = ValueNotifier<bool>(true);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: showHost,
              builder: (context, visible, _) {
                if (!visible) return const SizedBox.shrink();
                return Center(
                  child: AnimatedDropdownMenu(
                    menuWidth: 200,
                    trigger: (context, showMenu) => TextButton(
                      onPressed: showMenu,
                      child: const Text('Open'),
                    ),
                    menuBuilder: (menuContext, hideMenu) => SizedBox(
                      width: 200,
                      child: Material(
                        child: MenuItemRow(
                          icon: Icons.location_on_outlined,
                          label: 'Find My',
                          onTap: () => hideMenu().then((_) async {
                            await pending.future;
                            sawUnmounted = !menuContext.mounted;
                          }),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Find My'));
      await tester.pumpAndSettle();

      showHost.value = false;
      await tester.pumpAndSettle();

      pending.complete();
      await tester.pump();

      expect(sawUnmounted, isTrue);
    },
  );
}
