import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bluebubbles/app/components/app_notice_bar.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_holder.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart' show StickerPlacement;
import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:bluebubbles/services/network/api/sticker_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:get_it/get_it.dart';

class _SilentLogger extends BaseLogger {
  @override
  void debug(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void info(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void warn(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}

  @override
  void error(dynamic log, {String? tag, Object? error, StackTrace? trace}) {}
}

class _TestSettings extends Settings {
  @override
  Future<Settings> saveManyAsync(List<String> keys) async => this;
}

class _RepositionCall {
  _RepositionCall({
    required this.chatGuid,
    required this.messageGuid,
    required this.placement,
  });

  final String chatGuid;
  final String messageGuid;
  final StickerPlacement placement;
}

class _FakeStickerApi extends StickerApi {
  _FakeStickerApi() : super(HttpService());

  final List<_RepositionCall> calls = [];
  Object? nextError;
  Completer<void>? pendingGate;

  @override
  Future<Response> reposition({
    required String chatGuid,
    required String messageGuid,
    required StickerPlacement placement,
    CancelToken? cancelToken,
  }) async {
    calls.add(_RepositionCall(
      chatGuid: chatGuid,
      messageGuid: messageGuid,
      placement: placement,
    ));
    if (pendingGate != null) {
      await pendingGate!.future;
    }
    if (nextError != null) {
      final err = nextError!;
      nextError = null;
      throw err;
    }
    return Response(
      requestOptions: RequestOptions(path: '/api/v2/message/sticker/$messageGuid/reposition'),
      statusCode: 200,
      data: {'status': 200},
    );
  }
}

class _FakeHttpService extends HttpService {
  _FakeHttpService(this.fakeSticker);

  final _FakeStickerApi fakeSticker;

  @override
  StickerApi get sticker => fakeSticker;
}

class _RecordingAdapter implements HttpClientAdapter {
  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    return ResponseBody.fromString(
      jsonEncode({'status': 200, 'data': {}}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _StubBaseApi implements BaseApi {
  _StubBaseApi(this.dio);

  @override
  final Dio dio;

  @override
  String get origin => 'http://localhost:1234';

  @override
  String get apiRoot => '$origin/api/v1';

  @override
  String get apiRootV2 => '$origin/api/v2';

  @override
  Map<String, String> get headers => const {};

  @override
  Map<String, dynamic> buildQueryParams([Map<String, dynamic> params = const {}]) =>
      {...params, 'guid': 'secret'};

  @override
  Future<Response> runApiGuarded(Future<Response> Function() func, {bool checkOrigin = true}) => func();

  @override
  Future<Response> returnSuccessOrError(Response r) => Future.value(r);
}

late Uint8List _kPng120x120;

Future<Uint8List> _createSolidPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF4CAF50),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

void _resetSingleton<T extends Object>(T instance) {
  if (GetIt.I.isRegistered<T>()) {
    GetIt.I.unregister<T>();
  }
  GetIt.I.registerSingleton<T>(instance);
}

_FakeStickerApi _registerTestServices() {
  Get.testMode = true;
  _resetSingleton<BaseLogger>(_SilentLogger());
  _resetSingleton<SettingsService>(SettingsService()..settings = _TestSettings());
  _resetSingleton<FilesystemService>(FilesystemService()..appDocDir = Directory.systemTemp);
  final stickerApi = _FakeStickerApi();
  _resetSingleton<HttpService>(_FakeHttpService(stickerApi));
  return stickerApi;
}

Message _makeStickerMessage({
  required String guid,
  required StickerPlacement placement,
  bool isFromMe = true,
  String? attachmentGuid,
  int attachmentId = 0,
}) {
  final attachment = Attachment(
    id: attachmentId,
    guid: attachmentGuid ?? 'at_0_$guid',
    mimeType: 'image/png',
    transferName: 'sticker.png',
    stickerPlacement: placement.toMap(),
    bytes: _kPng120x120,
  );
  final msg = Message(
    guid: guid,
    associatedMessageGuid: 'PARENT-GUID',
    associatedMessageType: 'sticker',
    associatedMessagePart: 0,
    isFromMe: isFromMe,
    dateCreated: DateTime(2026, 1, 1, 12, 0, 0),
  );
  msg.dbAttachments.add(attachment);
  return msg;
}

Widget _buildStickerHarness({
  required Chat chat,
  required Message parentMsg,
  required MessageState state,
  required List<Message> stickers,
  Size bubbleSize = const Size(240, 120),
  VoidCallback? onBackdropTap,
}) {
  return MaterialApp(
    home: AppNoticeHost(
      child: Scaffold(
        body: Column(
          children: [
            ValueListenableBuilder<AppNoticeData?>(
              valueListenable: AppNoticeController.instance.current,
              builder: (context, notice, _) {
                if (notice == null) return const SizedBox.shrink();
                return AppNoticeTopBar(
                  notice: notice,
                  onDismiss: () => AppNoticeController.instance.dismiss(explicit: true),
                );
              },
            ),
            Expanded(
              child: Center(
                child: ChatStateScope(
                  chatState: ChatState(chat),
                  child: MessageStateScope(
                    messageState: state,
                    child: SizedBox(
                      width: bubbleSize.width,
                      height: bubbleSize.height,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              key: const ValueKey('bubble_backdrop'),
                              onTap: onBackdropTap,
                              child: const ColoredBox(color: Colors.black12),
                            ),
                          ),
                          Positioned.fill(
                            child: StickerHolder(
                              stickerMessages: stickers,
                              isFromMe: parentMsg.isFromMe ?? false,
                              tailGutter: false,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _pumpHarness(WidgetTester tester, Widget harness) async {
  await tester.pumpWidget(harness);
  await tester.runAsync(() async {
    await precacheImage(
      MemoryImage(_kPng120x120, scale: 3.0),
      tester.element(find.byType(StickerHolder)),
    );
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeStickerApi fakeStickerApi;

  setUpAll(() async {
    _kPng120x120 = await _createSolidPng(120, 120);
  });

  setUp(() {
    resetErrorIssuesForTest();
    fakeStickerApi = _registerTestServices();
  });

  tearDown(() async {
    resetErrorIssuesForTest();
    await GetIt.I.reset();
  });

  group('StickerApi.reposition', () {
    test('posts chatGuid and placement.toMap() to /api/v2/message/sticker/:guid/reposition', () async {
      final adapter = _RecordingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final api = StickerApi(_StubBaseApi(dio));

      const placement = StickerPlacement(
        xScalar: 0.72,
        yScalar: 0.31,
        scale: 1.45,
        rotation: -0.35,
        parentPreviewWidth: 240,
      );

      final response = await api.reposition(
        chatGuid: 'iMessage;-;+15551234567',
        messageGuid: 'STICKER-MSG-1',
        placement: placement,
      );

      expect(response.statusCode, equals(200));
      final req = adapter.lastOptions;
      expect(req, isNotNull);
      expect(req!.method, equals('POST'));
      expect(req.uri.path, equals('/api/v2/message/sticker/STICKER-MSG-1/reposition'));
      expect(req.queryParameters['guid'], equals('secret'));
      expect(
        req.data,
        equals({
          'chatGuid': 'iMessage;-;+15551234567',
          'xScalar': 0.72,
          'yScalar': 0.31,
          'scale': 1.45,
          'rotation': -0.35,
          'parentPreviewWidth': 240.0,
        }),
      );
    });

    test('rejects empty messageGuid or invalid placement', () async {
      final dio = Dio()..httpClientAdapter = _RecordingAdapter();
      final api = StickerApi(_StubBaseApi(dio));

      await expectLater(
        () => api.reposition(
          chatGuid: 'iMessage;-;+15551234567',
          messageGuid: '',
          placement: StickerPlacement.centeredDefault,
        ),
        throwsArgumentError,
      );
      await expectLater(
        () => api.reposition(
          chatGuid: 'iMessage;-;+15551234567',
          messageGuid: 'STICKER-MSG-1',
          placement: const StickerPlacement(
            xScalar: 0.5,
            yScalar: 0.5,
            scale: 0,
            rotation: 0,
            parentPreviewWidth: 240,
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('StickerHolder post-send repositioning', () {
    testWidgets('dragging own iMessage sticker updates live placement, calls API, and persists attachment',
        (tester) async {
      const initial = StickerPlacement(
        xScalar: 0.5,
        yScalar: 0.5,
        scale: 1.0,
        rotation: 0.0,
        parentPreviewWidth: 240,
      );
      final stickerMsg = _makeStickerMessage(guid: 'STICKER-OWN-1', placement: initial);
      final parentMsg = Message(guid: 'PARENT-GUID', text: 'hi', isFromMe: true);
      parentMsg.associatedMessages.add(stickerMsg);
      final state = MessageState(parentMsg);
      final chat = Chat(guid: 'iMessage;-;+15551234567');

      await _pumpHarness(
        tester,
        _buildStickerHarness(
          chat: chat,
          parentMsg: parentMsg,
          state: state,
          stickers: [stickerMsg],
        ),
      );

      final stickerFinder = find.byKey(const ValueKey<Object>('at_0_STICKER-OWN-1'));
      final stickerImageFinder = find.descendant(of: stickerFinder, matching: find.byType(Image));
      expect(stickerFinder, findsOneWidget);
      // Own non-temp iMessage sticker should not be wrapped in IgnorePointer
      expect(find.descendant(of: stickerFinder, matching: find.byType(IgnorePointer)), findsNothing);

      final beforePos = tester.widget<Positioned>(stickerFinder);
      expect(beforePos.left, closeTo(120.0, 1e-4));
      expect(beforePos.top, closeTo(60.0, 1e-4));

      // Drag past kPanSlop (36px) in steps so we can assert live redraw before pointer release
      final center = tester.getCenter(stickerImageFinder);
      final gesture = await tester.startGesture(center);
      await tester.pump();
      await gesture.moveBy(const Offset(48, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(12, 24));
      await tester.pump();

      // Live redraw updated Positioned while gesture is still active
      final midPos = tester.widget<Positioned>(stickerFinder);
      expect(midPos.left!, greaterThan(120.0));
      expect(midPos.top!, greaterThan(60.0));
      expect(fakeStickerApi.calls, isEmpty);

      // Release -> triggers API call & persistence
      await gesture.up();
      await tester.pumpAndSettle();

      expect(fakeStickerApi.calls, hasLength(1));
      final call = fakeStickerApi.calls.single;
      expect(call.chatGuid, equals('iMessage;-;+15551234567'));
      expect(call.messageGuid, equals('STICKER-OWN-1'));
      expect(call.placement.xScalar, greaterThan(0.5));
      expect(call.placement.yScalar, greaterThan(0.5));
      expect(call.placement.scale, closeTo(1.0, 1e-6));
      expect(call.placement.rotation, closeTo(0.0, 1e-6));
      expect(call.placement.parentPreviewWidth, closeTo(240.0, 1e-6));

      // Attachment stickerPlacement updated and remains at the new position
      final persisted = StickerPlacement.tryParse(stickerMsg.dbAttachments.single.stickerPlacement);
      expect(persisted, equals(call.placement));
      final afterPos = tester.widget<Positioned>(stickerFinder);
      expect(afterPos.left, closeTo(call.placement.xScalar * 240.0, 1e-4));
      expect(afterPos.top, closeTo(call.placement.yScalar * 120.0, 1e-4));
    });

    testWidgets('pinch/trackpad scale & rotation updates sticker and clamps scale to 0.25..4.0', (tester) async {
      const initial = StickerPlacement(
        xScalar: 0.5,
        yScalar: 0.5,
        scale: 1.5,
        rotation: 0.2,
        parentPreviewWidth: 240,
      );
      final stickerMsg = _makeStickerMessage(guid: 'STICKER-SCALE-1', placement: initial);
      final parentMsg = Message(guid: 'PARENT-GUID', text: 'hi', isFromMe: true);
      parentMsg.associatedMessages.add(stickerMsg);
      final state = MessageState(parentMsg);
      final chat = Chat(guid: 'iMessage;-;+15551234567');

      await _pumpHarness(
        tester,
        _buildStickerHarness(
          chat: chat,
          parentMsg: parentMsg,
          state: state,
          stickers: [stickerMsg],
        ),
      );

      final stickerFinder = find.byKey(const ValueKey<Object>('at_0_STICKER-SCALE-1'));
      final stickerImageFinder = find.descendant(of: stickerFinder, matching: find.byType(Image));
      final center = tester.getCenter(stickerImageFinder);

      // Simulate trackpad PanZoom (used on Web/macOS and exercises ScaleGestureRecognizer scale + rotation).
      // First update crosses pan slop to accept the gesture, establishing the baseline for subsequent scale/rotation.
      final pointer = TestPointer(1, PointerDeviceKind.trackpad);
      tester.binding.handlePointerEvent(pointer.panZoomStart(center));
      await tester.pump();
      tester.binding.handlePointerEvent(pointer.panZoomUpdate(
        center,
        pan: const Offset(40, 0),
      ));
      await tester.pump();
      tester.binding.handlePointerEvent(pointer.panZoomUpdate(
        center,
        pan: const Offset(52, -6),
        scale: 1.5,
        rotation: 0.5,
      ));
      await tester.pump();

      // Live rotation transform reflects initial (0.2) + delta (0.5) = 0.7 rad
      final liveRotate = tester.widget<Transform>(
        find.descendant(of: stickerFinder, matching: find.byType(Transform)).first,
      );
      expect(liveRotate.transform.entry(0, 0), closeTo(math.cos(0.7), 1e-4));
      expect(liveRotate.transform.entry(1, 0), closeTo(math.sin(0.7), 1e-4));

      tester.binding.handlePointerEvent(pointer.panZoomEnd());
      await tester.pumpAndSettle();

      expect(fakeStickerApi.calls, hasLength(1));
      final firstCall = fakeStickerApi.calls.single;
      expect(firstCall.placement.scale, closeTo(2.25, 1e-6));
      expect(firstCall.placement.rotation, closeTo(0.7, 1e-6));

      // Now scale beyond 4.0 and verify upper clamp to 4.0
      final center2 = tester.getCenter(stickerImageFinder);
      final pointer2 = TestPointer(2, PointerDeviceKind.trackpad);
      tester.binding.handlePointerEvent(pointer2.panZoomStart(center2));
      await tester.pump();
      tester.binding.handlePointerEvent(pointer2.panZoomUpdate(center2, pan: const Offset(40, 0)));
      await tester.pump();
      tester.binding.handlePointerEvent(pointer2.panZoomUpdate(center2, pan: const Offset(40, 0), scale: 3.0));
      await tester.pump();
      tester.binding.handlePointerEvent(pointer2.panZoomEnd());
      await tester.pumpAndSettle();

      expect(fakeStickerApi.calls, hasLength(2));
      expect(fakeStickerApi.calls[1].placement.scale, closeTo(4.0, 1e-6));

      // Now scale below 0.25 and verify lower clamp to 0.25
      final center3 = tester.getCenter(stickerImageFinder);
      final pointer3 = TestPointer(3, PointerDeviceKind.trackpad);
      tester.binding.handlePointerEvent(pointer3.panZoomStart(center3));
      await tester.pump();
      tester.binding.handlePointerEvent(pointer3.panZoomUpdate(center3, pan: const Offset(40, 0)));
      await tester.pump();
      tester.binding.handlePointerEvent(pointer3.panZoomUpdate(center3, pan: const Offset(40, 0), scale: 0.01));
      await tester.pump();
      tester.binding.handlePointerEvent(pointer3.panZoomEnd());
      await tester.pumpAndSettle();

      expect(fakeStickerApi.calls, hasLength(3));
      expect(fakeStickerApi.calls[2].placement.scale, closeTo(0.25, 1e-6));
    });

    testWidgets('rolls back placement and shows error snackbar when StickerApi.reposition fails', (tester) async {
      const initial = StickerPlacement(
        xScalar: 0.5,
        yScalar: 0.5,
        scale: 1.0,
        rotation: 0.0,
        parentPreviewWidth: 240,
      );
      final stickerMsg = _makeStickerMessage(guid: 'STICKER-ERR-1', placement: initial);
      final parentMsg = Message(guid: 'PARENT-GUID', text: 'hi', isFromMe: true);
      parentMsg.associatedMessages.add(stickerMsg);
      final state = MessageState(parentMsg);
      final chat = Chat(guid: 'iMessage;-;+15551234567');

      final gate = Completer<void>();
      fakeStickerApi.pendingGate = gate;
      fakeStickerApi.nextError = DioException(
        requestOptions: RequestOptions(path: '/api/v2/message/sticker/STICKER-ERR-1/reposition'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/v2/message/sticker/STICKER-ERR-1/reposition'),
          statusCode: 500,
          data: {
            'error': {'message': 'Reposition refused by server'},
          },
        ),
      );

      await _pumpHarness(
        tester,
        _buildStickerHarness(
          chat: chat,
          parentMsg: parentMsg,
          state: state,
          stickers: [stickerMsg],
        ),
      );

      final stickerFinder = find.byKey(const ValueKey<Object>('at_0_STICKER-ERR-1'));
      final stickerImageFinder = find.descendant(of: stickerFinder, matching: find.byType(Image));
      final center = tester.getCenter(stickerImageFinder);

      await tester.drag(stickerImageFinder, const Offset(60, 20));
      await tester.pump();

      // While request is in flight, sticker stays at dragged position
      final duringPos = tester.widget<Positioned>(stickerFinder);
      expect(duringPos.left!, greaterThan(120.0));
      expect(fakeStickerApi.calls, hasLength(1));

      // Complete API failure -> rolls back to initial placement and shows error snackbar
      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final rolledBackPos = tester.widget<Positioned>(stickerFinder);
      expect(rolledBackPos.left, closeTo(120.0, 1e-4));
      expect(rolledBackPos.top, closeTo(60.0, 1e-4));
      expect(StickerPlacement.tryParse(stickerMsg.dbAttachments.single.stickerPlacement), equals(initial));
      expect(find.text('Reposition refused by server'), findsOneWidget);

      // Also verify _dragging didn't leak by confirming center is back
      expect(tester.getCenter(stickerImageFinder).dx, closeTo(center.dx, 1e-2));

      // Flush the 4s auto-close timer of AppNoticeHost cleanly before test teardown
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('non-own, temp, and non-iMessage stickers keep IgnorePointer and pass taps through', (tester) async {
      const initial = StickerPlacement(
        xScalar: 0.5,
        yScalar: 0.5,
        scale: 1.0,
        rotation: 0.0,
        parentPreviewWidth: 240,
      );

      // 1. Non-own sticker (isFromMe: false) in iMessage chat
      var backdropTapped = 0;
      final incomingSticker = _makeStickerMessage(
        guid: 'STICKER-INCOMING-1',
        placement: initial,
        isFromMe: false,
      );
      final parentMsg = Message(guid: 'PARENT-GUID', text: 'hi', isFromMe: false);
      parentMsg.associatedMessages.add(incomingSticker);
      final state1 = MessageState(parentMsg);
      final imessageChat = Chat(guid: 'iMessage;-;+15551234567');

      await _pumpHarness(
        tester,
        _buildStickerHarness(
          chat: imessageChat,
          parentMsg: parentMsg,
          state: state1,
          stickers: [incomingSticker],
          onBackdropTap: () => backdropTapped++,
        ),
      );

      final incomingFinder = find.byKey(const ValueKey<Object>('at_0_STICKER-INCOMING-1'));
      final incomingImageFinder = find.descendant(of: incomingFinder, matching: find.byType(Image));
      expect(find.descendant(of: incomingFinder, matching: find.byType(IgnorePointer)), findsOneWidget);

      // Tapping over the non-own sticker passes through to the underlying bubble
      await tester.tapAt(tester.getCenter(incomingImageFinder));
      await tester.pumpAndSettle();
      expect(backdropTapped, equals(1));

      await tester.drag(incomingImageFinder, const Offset(60, 20), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(fakeStickerApi.calls, isEmpty);

      // 2. Temp own sticker in iMessage chat
      final tempSticker = _makeStickerMessage(
        guid: 'temp-STICKER-2',
        attachmentGuid: 'temp-at-2',
        placement: initial,
        isFromMe: true,
      );
      final state2 = MessageState(Message(guid: 'PARENT-2', text: 'hi', isFromMe: true));
      await _pumpHarness(
        tester,
        _buildStickerHarness(
          chat: imessageChat,
          parentMsg: state2.message,
          state: state2,
          stickers: [tempSticker],
        ),
      );

      final tempFinder = find.byKey(const ValueKey<Object>('temp-at-2'));
      final tempImageFinder = find.descendant(of: tempFinder, matching: find.byType(Image));
      expect(find.descendant(of: tempFinder, matching: find.byType(IgnorePointer)), findsOneWidget);
      await tester.drag(tempImageFinder, const Offset(60, 20), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(fakeStickerApi.calls, isEmpty);

      // 3. Own non-temp sticker in non-iMessage (RCS) chat
      final rcsChat = Chat(guid: 'RCS;-;+15551234567');
      final rcsSticker = _makeStickerMessage(
        guid: 'STICKER-RCS-3',
        placement: initial,
        isFromMe: true,
      );
      final state3 = MessageState(Message(guid: 'PARENT-3', text: 'hi', isFromMe: true));
      await _pumpHarness(
        tester,
        _buildStickerHarness(
          chat: rcsChat,
          parentMsg: state3.message,
          state: state3,
          stickers: [rcsSticker],
        ),
      );

      final rcsFinder = find.byKey(const ValueKey<Object>('at_0_STICKER-RCS-3'));
      final rcsImageFinder = find.descendant(of: rcsFinder, matching: find.byType(Image));
      expect(find.descendant(of: rcsFinder, matching: find.byType(IgnorePointer)), findsOneWidget);
      await tester.drag(rcsImageFinder, const Offset(60, 20), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(fakeStickerApi.calls, isEmpty);
    });
  });
}
