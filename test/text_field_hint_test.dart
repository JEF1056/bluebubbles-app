import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_component.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TextFieldComponentState.hintTextForService', () {
    test('Material skin shows iMessage for iMessage chats', () {
      expect(
        TextFieldComponentState.hintTextForService(
          material: true,
          isRCS: false,
          isIMessage: true,
        ),
        'iMessage',
      );
    });

    test('Material skin shows RCS message for RCS and Text message for SMS', () {
      expect(
        TextFieldComponentState.hintTextForService(
          material: true,
          isRCS: true,
          isIMessage: false,
        ),
        'RCS message',
      );
      expect(
        TextFieldComponentState.hintTextForService(
          material: true,
          isRCS: false,
          isIMessage: false,
        ),
        'Text message',
      );
    });

    test('Non-Material skins preserve iMessage / RCS / Text Forwarding hints', () {
      expect(
        TextFieldComponentState.hintTextForService(
          material: false,
          isRCS: false,
          isIMessage: true,
        ),
        'iMessage',
      );
      expect(
        TextFieldComponentState.hintTextForService(
          material: false,
          isRCS: true,
          isIMessage: false,
        ),
        'Text Message • RCS',
      );
      expect(
        TextFieldComponentState.hintTextForService(
          material: false,
          isRCS: false,
          isIMessage: false,
        ),
        'Text Forwarding',
      );
    });
  });
}
