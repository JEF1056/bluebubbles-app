import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/bubble_effects.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/tail_clipper.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/animations/balloon_classes.dart';
import 'package:bluebubbles/app/animations/balloon_rendering.dart';
import 'package:bluebubbles/app/animations/celebration_class.dart';
import 'package:bluebubbles/app/animations/celebration_rendering.dart';
import 'package:bluebubbles/app/animations/fireworks_classes.dart';
import 'package:bluebubbles/app/animations/fireworks_rendering.dart';
import 'package:bluebubbles/app/animations/laser_classes.dart';
import 'package:bluebubbles/app/animations/laser_rendering.dart';
import 'package:bluebubbles/app/animations/love_classes.dart';
import 'package:bluebubbles/app/animations/love_rendering.dart';
import 'package:bluebubbles/app/animations/spotlight_classes.dart';
import 'package:bluebubbles/app/animations/spotlight_rendering.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:bluebubbles/platform/shims/window_effect.dart';
import 'package:get/get.dart';
import 'package:simple_animations/simple_animations.dart';
import 'package:supercharged/supercharged.dart';

void sendEffectAction(
  BuildContext context,
  TickerProvider provider,
  String text,
  String subjectText,
  String? threadOriginatorGuid,
  int? part,
  String? chatGuid,
  Future<void> Function({String? effect}) sendMessage,
  List<Run> textRuns,
) {
  if (!SettingsSvc.settings.enablePrivateAPI.value) return;
  final lead = text.length - text.trimLeft().length;
  text = text.trim();
  // Runs over the trimmed whitespace are cut back to the text, or they'd fall outside it and not be drawn
  final trimmedRuns = <Run>[];
  for (final r in textRuns) {
    final start = max(r.range[0] - lead, 0);
    final end = min(r.range[0] + r.range[1] - lead, text.length);
    if (end > start) trimmedRuns.add(Run(range: [start, end - start], attributes: r.attributes));
  }
  final runs = MentionTextEditingController.attributedRuns(text, trimmedRuns);
  final message = Message(
    text: text,
    subject: subjectText,
    threadOriginatorGuid: threadOriginatorGuid,
    threadOriginatorPart: "${part ?? 0}:0:0",
    expressiveSendStyleId: effectMap["slam"],
    dateCreated: DateTime.now(),
    hasAttachments: false,
    isFromMe: true,
    handleId: 0,
    hasDdResults: true,
    attributedBody: [if (runs.isNotEmpty) AttributedBody(string: text, runs: runs)],
  );
  message.generateTempGuid();
  // Capture the conversation's theme before pushing the route — if adaptive
  // theming is active, context.theme is already the per-chat theme.
  final capturedTheme = context.theme;
  final capturedIsM3 = ThemeSvc.isMaterialYouActive(context);
  final capturedBubbleExt = capturedTheme.extensions[BubbleColors] as BubbleColors?;
  Navigator.push(
    context,
    PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, animation, secondaryAnimation) {
        return FadeTransition(
          opacity: animation,
          child: _SendEffectPickerOverlay(
            message: message,
            text: text,
            subjectText: subjectText,
            sendMessage: sendMessage,
            capturedTheme: capturedTheme,
            capturedIsM3: capturedIsM3,
            capturedBubbleExt: capturedBubbleExt,
          ),
        );
      },
      fullscreenDialog: true,
      opaque: false,
    ),
  );
}

class _SendEffectPickerOverlay extends StatefulWidget {
  const _SendEffectPickerOverlay({
    required this.message,
    required this.text,
    required this.subjectText,
    required this.sendMessage,
    required this.capturedTheme,
    required this.capturedIsM3,
    required this.capturedBubbleExt,
  });

  final Message message;
  final String text;
  final String subjectText;
  final Future<void> Function({String? effect}) sendMessage;
  final ThemeData capturedTheme;
  final bool capturedIsM3;
  final BubbleColors? capturedBubbleExt;

  @override
  State<_SendEffectPickerOverlay> createState() => _SendEffectPickerOverlayState();
}

class _SendEffectPickerOverlayState extends State<_SendEffectPickerOverlay> with TickerProviderStateMixin {
  static const List<String> _bubbleEffects = ["slam", "loud", "gentle", "invisible ink"];
  static const List<String> _screenEffects = [
    "echo",
    "spotlight",
    "balloons",
    "confetti",
    "love",
    "lasers",
    "fireworks",
    "celebration",
  ];

  String _typeSelected = "bubble";
  String _bubbleSelected = "slam";
  String _screenSelected = "echo";
  late final MessageState _previewState = MessageState(widget.message);
  final GlobalKey _bubbleKey = GlobalKey();
  Control _animController = Control.stop;

  late final FireworkController _fireworkController;
  late final CelebrationController _celebrationController;
  late final ConfettiController _confettiController;
  late final BalloonController _balloonController;
  late final LoveController _loveController;
  late final SpotlightController _spotlightController;
  late final LaserController _laserController;
  bool _controllersInitialized = false;
  Timer? _effectStopTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controllersInitialized) return;
    final windowSize = Size(NavigationSvc.width(context), context.height);
    _fireworkController = FireworkController(vsync: this, windowSize: windowSize);
    _celebrationController = CelebrationController(vsync: this, windowSize: windowSize);
    _confettiController = ConfettiController(duration: const Duration(seconds: 1));
    _balloonController = BalloonController(vsync: this, windowSize: windowSize);
    _loveController = LoveController(vsync: this, windowSize: windowSize);
    _spotlightController = SpotlightController(vsync: this, windowSize: windowSize);
    _laserController = LaserController(vsync: this, windowSize: windowSize);
    _controllersInitialized = true;
  }

  @override
  void dispose() {
    _effectStopTimer?.cancel();
    _effectStopTimer = null;
    if (_controllersInitialized) {
      _fireworkController.dispose();
      _celebrationController.dispose();
      _confettiController.dispose();
      _balloonController.dispose();
      _loveController.dispose();
      _spotlightController.dispose();
      _laserController.dispose();
    }
    super.dispose();
  }

  void _scheduleEffectStop(VoidCallback stopFn) {
    _effectStopTimer?.cancel();
    _effectStopTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) stopFn();
    });
  }

  @override
  Widget build(BuildContext context) {
    final capturedTheme = widget.capturedTheme;
    final capturedIsM3 = widget.capturedIsM3;
    final capturedBubbleExt = widget.capturedBubbleExt;
    return GestureDetector(
      onTap: () {
        Navigator.of(context).pop();
      },
      child: BBScaffold(
        backgroundColor: kIsDesktop && SettingsSvc.settings.windowEffect.value != WindowEffect.disabled
            ? capturedTheme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.9)
            : Colors.transparent,
        safeAreaLeft: false,
        safeAreaRight: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            BackdropFilter(
              filter: ImageFilter.blur(
                  sigmaX: kIsDesktop && SettingsSvc.settings.windowEffect.value != WindowEffect.disabled ? 0 : 30,
                  sigmaY: kIsDesktop && SettingsSvc.settings.windowEffect.value != WindowEffect.disabled ? 0 : 30),
              child: Container(
                color: capturedTheme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              ),
            ),
            Stack(
              children: [
                if (_screenSelected == "fireworks") Fireworks(controller: _fireworkController),
                if (_screenSelected == "celebration") Celebration(controller: _celebrationController),
                if (_screenSelected == "balloons") Balloons(controller: _balloonController),
                if (_screenSelected == "love") Love(controller: _loveController),
                if (_screenSelected == "spotlight") Spotlight(controller: _spotlightController),
                if (_screenSelected == "lasers") Laser(controller: _laserController),
                if (_screenSelected == "confetti")
                  Align(
                    alignment: Alignment.topCenter,
                    child: ConfettiWidget(
                      confettiController: _confettiController,
                      blastDirection: pi / 2,
                      blastDirectionality: BlastDirectionality.explosive,
                      emissionFrequency: 0.35,
                    ),
                  ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20.0),
                    child: Center(
                        child: Column(children: [
                      Text(
                        "Send with effect",
                        style: context.theme.textTheme.headlineSmall!,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20.0),
                        child: SizedBox(
                          height: 50,
                          width: NavigationSvc.width(context) / 2,
                          child: CupertinoSlidingSegmentedControl<String>(
                            children: {
                              "bubble": const Text("Bubble"),
                              "screen": const Text("Screen"),
                            },
                            groupValue: _typeSelected,
                            thumbColor: CupertinoColors.tertiarySystemFill.oppositeLightenOrDarken(20),
                            backgroundColor: CupertinoColors.tertiarySystemFill,
                            onValueChanged: (str) {
                              setState(() {
                                _typeSelected = str ?? "bubble";
                              });
                            },
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (_typeSelected == "bubble")
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20.0),
                          child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: 250,
                                maxWidth: NavigationSvc.width(context),
                              ),
                              child: SingleChildScrollView(
                                child: Wrap(
                                  alignment: WrapAlignment.center,
                                  children: List.generate(_bubbleEffects.length, (index) {
                                    return Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            _bubbleSelected = _bubbleEffects[index];
                                            widget.message.expressiveSendStyleId = effectMap[_bubbleSelected];
                                            _previewState.triggerBubbleEffect(0);
                                            if (_bubbleSelected == "gentle") {
                                              _animController = Control.playFromStart;
                                            }
                                          });
                                        },
                                        child: Container(
                                          width: NavigationSvc.width(context) / 3,
                                          height: 50,
                                          decoration: BoxDecoration(
                                            color: CupertinoColors.tertiarySystemFill,
                                            border: Border.fromBorderSide(_bubbleSelected == _bubbleEffects[index]
                                                ? BorderSide(
                                                    color: context.theme.colorScheme.primary,
                                                    width: 1.5,
                                                    style: BorderStyle.solid,
                                                  )
                                                : BorderSide.none),
                                            borderRadius: BorderRadius.circular(5),
                                          ),
                                          child: Center(
                                            child: Text(
                                              _bubbleEffects[index].toUpperCase(),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }),
                                ),
                              )),
                        ),
                      if (_typeSelected == "screen")
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20.0),
                          child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: 350,
                                maxWidth: NavigationSvc.width(context),
                              ),
                              child: SingleChildScrollView(
                                child: Wrap(
                                  alignment: WrapAlignment.center,
                                  children: List.generate(_screenEffects.length, (index) {
                                    return Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            _screenSelected = _screenEffects[index];
                                          });
                                          if (_screenSelected == "fireworks" && !_fireworkController.isPlaying) {
                                            _fireworkController.windowSize =
                                                Size(NavigationSvc.width(context), context.height);
                                            _fireworkController.start();
                                            _scheduleEffectStop(_fireworkController.stop);
                                          } else if (_screenSelected == "celebration" &&
                                              !_celebrationController.isPlaying) {
                                            _celebrationController.windowSize =
                                                Size(NavigationSvc.width(context), context.height);
                                            _celebrationController.start();
                                            _scheduleEffectStop(_celebrationController.stop);
                                          } else if (_screenSelected == "balloons" && !_balloonController.isPlaying) {
                                            _balloonController.windowSize =
                                                Size(NavigationSvc.width(context), context.height);
                                            _balloonController.start();
                                            _scheduleEffectStop(_balloonController.stop);
                                          } else if (_screenSelected == "love" && !_loveController.isPlaying) {
                                            final bounds = _bubbleKey.globalPaintBounds(context);
                                            if (bounds != null) {
                                              _loveController.windowSize =
                                                  Size(NavigationSvc.width(context), context.height);
                                              _loveController.start(Point(
                                                  (bounds.left + bounds.right) / 2, (bounds.top + bounds.bottom) / 2));
                                              _scheduleEffectStop(_loveController.stop);
                                            }
                                          } else if (_screenSelected == "spotlight" &&
                                              !_spotlightController.isPlaying) {
                                            final bounds = _bubbleKey.globalPaintBounds(context);
                                            if (bounds != null) {
                                              _spotlightController.windowSize =
                                                  Size(NavigationSvc.width(context), context.height);
                                              _spotlightController.start(bounds);
                                              _scheduleEffectStop(_spotlightController.stop);
                                            }
                                          } else if (_screenSelected == "lasers" && !_laserController.isPlaying) {
                                            final bounds = _bubbleKey.globalPaintBounds(context);
                                            if (bounds != null) {
                                              _laserController.windowSize =
                                                  Size(NavigationSvc.width(context), context.height);
                                              _laserController.start(bounds);
                                              _scheduleEffectStop(_laserController.stop);
                                            }
                                          } else if (_screenSelected == "confetti") {
                                            _confettiController.play();
                                          }
                                        },
                                        child: Container(
                                          width: NavigationSvc.width(context) / 3,
                                          height: 50,
                                          decoration: BoxDecoration(
                                            color: CupertinoColors.tertiarySystemFill,
                                            border: Border.fromBorderSide(_screenSelected == _screenEffects[index]
                                                ? BorderSide(
                                                    color: context.theme.colorScheme.primary,
                                                    width: 1.5,
                                                    style: BorderStyle.solid,
                                                  )
                                                : BorderSide.none),
                                            borderRadius: BorderRadius.circular(5),
                                          ),
                                          child: Center(
                                            child: Text(
                                              _screenEffects[index].toUpperCase(),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }),
                                ),
                              )),
                        ),
                      const Spacer(),
                      if (widget.text.isNotEmpty || widget.subjectText.isNotEmpty)
                        Theme(
                          data: capturedTheme.copyWith(
                            // in case some components still use legacy theming
                            primaryColor: capturedBubbleExt?.iMessageBubbleColor ?? capturedTheme.colorScheme.primary,
                            colorScheme: capturedTheme.colorScheme.copyWith(
                              primary: capturedBubbleExt?.iMessageBubbleColor ?? capturedTheme.colorScheme.primary,
                              onPrimary:
                                  capturedBubbleExt?.oniMessageBubbleColor ?? capturedTheme.colorScheme.onPrimary,
                              surface: capturedIsM3 ? null : capturedBubbleExt?.receivedBubbleColor,
                              onSurface: capturedIsM3 ? null : capturedBubbleExt?.onReceivedBubbleColor,
                            ),
                          ),
                          child: Builder(builder: (context) {
                            return Align(
                                alignment: Alignment.centerRight,
                                child: Padding(
                                  key: _bubbleKey,
                                  padding: const EdgeInsets.only(right: 5.0),
                                  child: BubbleEffects(
                                    messageState: _previewState,
                                    globalKey: _bubbleKey,
                                    part: 0,
                                    showTail: true,
                                    child: ClipPath(
                                      clipper: TailClipper(
                                        isFromMe: true,
                                        showTail: true,
                                        connectLower: false,
                                        connectUpper: false,
                                      ),
                                      child: Container(
                                        constraints: BoxConstraints(
                                          maxWidth:
                                              NavigationSvc.width(context) * MessageState.maxBubbleSizeFactor - 40,
                                          minHeight: 40,
                                        ),
                                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 15)
                                            .add(EdgeInsets.only(right: CurrentSkin.iOS ? 10 : 0)),
                                        color: context.theme.colorScheme.primary,
                                        child: CustomAnimationBuilder<Movie>(
                                          control: _animController,
                                          tween: MovieTween()
                                            ..scene(
                                                    begin: Duration.zero,
                                                    duration: const Duration(milliseconds: 1),
                                                    curve: Curves.easeInOut)
                                                .tween("size", 1.0.tweenTo(1.0))
                                            ..scene(
                                                    begin: const Duration(milliseconds: 1),
                                                    duration: const Duration(milliseconds: 500),
                                                    curve: Curves.easeInOut)
                                                .tween("size", 0.0.tweenTo(0.5))
                                            ..scene(
                                                    begin: const Duration(milliseconds: 1000),
                                                    duration: const Duration(milliseconds: 800),
                                                    curve: Curves.easeInOut)
                                                .tween("size", 0.5.tweenTo(1.0)),
                                          duration: const Duration(milliseconds: 1800),
                                          animationStatusListener: (status) {
                                            if (status == AnimationStatus.completed && mounted) {
                                              setState(() {
                                                _animController = Control.stop;
                                              });
                                            }
                                          },
                                          builder: (context, anim, child) {
                                            final value1 = anim.get("size");
                                            return Transform.scale(
                                              scale: value1,
                                              alignment: Alignment.center,
                                              child: RichText(
                                                text: TextSpan(
                                                  children: buildMessageSpans(
                                                    context,
                                                    MessagePart(
                                                        part: 0,
                                                        text: widget.message.text,
                                                        runs: widget.message.attributedBody.firstOrNull?.runs ?? []),
                                                    widget.message,
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ));
                          }),
                        ),
                      const Spacer(),
                      TextButton(
                        child: Text(
                          _typeSelected == "bubble" ? "Send with $_bubbleSelected" : "Send with $_screenSelected",
                          style: context.theme.textTheme.titleLarge!.apply(color: context.theme.colorScheme.primary),
                        ),
                        onPressed: () async {
                          Navigator.of(context).pop();
                          await widget.sendMessage(
                              effect: effectMap[_typeSelected == "bubble" ? _bubbleSelected : _screenSelected]);
                        },
                      ),
                    ])),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
