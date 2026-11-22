import 'package:bluebubbles/app/components/blur_fade_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StatefulProbe extends StatefulWidget {
  const _StatefulProbe({super.key, required this.label, this.onInit});

  final String label;
  final VoidCallback? onInit;

  @override
  State<_StatefulProbe> createState() => _StatefulProbeState();
}

class _StatefulProbeState extends State<_StatefulProbe> {
  @override
  void initState() {
    super.initState();
    widget.onInit?.call();
  }

  @override
  Widget build(BuildContext context) => Text(widget.label);
}

Widget _harness({
  required ValueKey<String> childKey,
  required String label,
  bool disableAnimations = false,
  bool animateSize = false,
  VoidCallback? onInit,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: BlurFadeSwitcher(
          animateSize: animateSize,
          child: _StatefulProbe(key: childKey, label: label, onInit: onInit),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('BlurFadeSwitcher blurs mid-swap, disables ImageFiltered when settled, and keeps child State',
      (tester) async {
    int secondInitCount = 0;

    await tester.pumpWidget(_harness(childKey: const ValueKey('a'), label: 'First'));
    expect(
      tester.widgetList<ImageFiltered>(find.byType(ImageFiltered)).every((w) => !w.enabled),
      isTrue,
    );

    await tester.pumpWidget(
      _harness(
        childKey: const ValueKey('b'),
        label: 'Second',
        onInit: () => secondInitCount++,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final midFilters = tester.widgetList<ImageFiltered>(find.byType(ImageFiltered)).toList();
    expect(midFilters, isNotEmpty);
    expect(midFilters.any((w) => w.enabled), isTrue);

    final midState = tester.state(find.byKey(const ValueKey('b')));

    await tester.pumpAndSettle();

    final settledFilters = tester.widgetList<ImageFiltered>(find.byType(ImageFiltered)).toList();
    expect(settledFilters.every((w) => !w.enabled), isTrue);
    expect(find.text('Second'), findsOneWidget);

    final settledState = tester.state(find.byKey(const ValueKey('b')));
    expect(identical(settledState, midState), isTrue);
    expect(secondInitCount, 1);
  });

  testWidgets('BlurFadeSwitcher bypasses switcher, AnimatedSize, and filter when disableAnimations is true',
      (tester) async {
    await tester.pumpWidget(
      _harness(childKey: const ValueKey('a'), label: 'First', disableAnimations: true, animateSize: true),
    );
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byType(AnimatedSwitcher), findsNothing);
    expect(find.byType(AnimatedSize), findsNothing);

    await tester.pumpWidget(
      _harness(childKey: const ValueKey('b'), label: 'Second', disableAnimations: true, animateSize: true),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byType(AnimatedSwitcher), findsNothing);
    expect(find.byType(AnimatedSize), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('motionDuration respects disableAnimations', (tester) async {
    const base = Duration(milliseconds: 200);
    late Duration enabledDuration;
    late Duration disabledDuration;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: false),
        child: Builder(builder: (context) {
          enabledDuration = motionDuration(context, base);
          return const SizedBox.shrink();
        }),
      ),
    );
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(builder: (context) {
          disabledDuration = motionDuration(context, base);
          return const SizedBox.shrink();
        }),
      ),
    );

    expect(enabledDuration, base);
    expect(disabledDuration, Duration.zero);
  });
}
