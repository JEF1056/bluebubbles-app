import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/material_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CurvedTopBarClipper', () {
    const clipper = CurvedTopBarClipper(radius: 26);

    test('includes bar body and corner ears while excluding rounded sheet corners', () {
      final path = clipper.getClip(const Size(400, 126));

      // Inside main bar area (barBottom = 100)
      expect(path.contains(const Offset(200, 50)), isTrue);
      // Below barBottom in center -> excluded so messages show behind
      expect(path.contains(const Offset(200, 105)), isFalse);
      // Outer left/right downward ears (distance from corner circle centers > 26)
      expect(path.contains(const Offset(2, 105)), isTrue);
      expect(path.contains(const Offset(398, 105)), isTrue);
      // Inside the 26dp rounded top-left and top-right body corners -> excluded
      expect(path.contains(const Offset(20, 120)), isFalse);
      expect(path.contains(const Offset(380, 120)), isFalse);
    });

    test('clamps radius on narrow or short sizes and checks shouldReclip', () {
      final narrowPath = clipper.getClip(const Size(30, 50));
      expect(narrowPath.contains(const Offset(15, 10)), isTrue);
      expect(narrowPath.contains(const Offset(15, 45)), isFalse);

      expect(clipper.shouldReclip(const CurvedTopBarClipper(radius: 26)), isFalse);
      expect(clipper.shouldReclip(const CurvedTopBarClipper(radius: 28)), isTrue);
    });
  });

  testWidgets('Scaffold extendBodyBehindAppBar exposes appBar height only to body descendant context', (tester) async {
    double? outerTopPadding;
    double? bodyTopPadding;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(top: 24)),
        child: MaterialApp(
          home: Builder(
            builder: (outerContext) {
              outerTopPadding = MediaQuery.paddingOf(outerContext).top;
              return Scaffold(
                extendBodyBehindAppBar: true,
                appBar: const PreferredSize(
                  preferredSize: Size.fromHeight(60),
                  child: SizedBox.expand(),
                ),
                body: Builder(
                  builder: (bodyContext) {
                    bodyTopPadding = MediaQuery.paddingOf(bodyContext).top;
                    return const SizedBox.shrink();
                  },
                ),
              );
            },
          ),
        ),
      ),
    );

    expect(outerTopPadding, 24);
    expect(bodyTopPadding, 84);
  });
}
