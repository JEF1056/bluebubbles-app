import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:bluebubbles/app/wrappers/chat_inspector_pane.dart';
import 'package:bluebubbles/app/wrappers/titlebar_wrapper.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

class TabletModeWrapper extends StatefulWidget {
  final Widget left;
  final Widget right;
  final double initialRatio;
  final double dividerWidth;
  final double minRatio;
  final double maxRatio;
  final bool allowResize;
  final double? minWidthLeft;
  final double? maxWidthLeft;
  final bool enableInspector;

  /// When set, the phone layout keeps [right] mounted over [left] and shows it while true, so pages survive a
  /// layout switch
  final RxBool? rightOpen;

  const TabletModeWrapper(
      {super.key,
      required this.left,
      required this.right,
      this.initialRatio = 0.5,
      this.allowResize = true,
      this.dividerWidth = 7.0,
      this.minRatio = 0,
      this.maxRatio = 0,
      this.minWidthLeft,
      this.maxWidthLeft,
      this.enableInspector = true,
      this.rightOpen})
      : assert(initialRatio >= 0),
        assert(initialRatio <= 1);

  static ({double leftWidth, double rightWidth, double inspectorReserved}) computePaneWidths({
    required double maxWidth,
    required double desiredLeftWidth,
    required bool showInspectorPane,
    required bool showInspectorToggle,
  }) {
    final inspectorReserved = showInspectorPane ? 321.0 : (showInspectorToggle ? 29.0 : 0.0);
    const minRightWidth = 360.0;
    final availableForLeft = max(0.0, maxWidth - inspectorReserved - minRightWidth);
    final leftWidth = min(desiredLeftWidth, availableForLeft);
    final rightWidth = max(0.0, maxWidth - leftWidth - inspectorReserved);
    return (leftWidth: leftWidth, rightWidth: rightWidth, inspectorReserved: inspectorReserved);
  }

  @override
  State<TabletModeWrapper> createState() => _TabletModeWrapperState();
}

class _TabletModeWrapperState extends State<TabletModeWrapper> with ThemeHelpers {
  //from 0-1
  late final RxDouble _ratio;

  double? _maxWidth;
  StreamSubscription? _eventSub;
  Worker? _activeChatWorker;

  double get _width1 => max(
      min(_ratio * _maxWidth!, widget.maxWidthLeft ?? double.infinity), widget.minWidthLeft ?? double.negativeInfinity);

  @override
  void initState() {
    super.initState();
    _ratio =
        RxDouble((PrefsSvc.desktop.getSplitRatio() ?? widget.initialRatio).clamp(widget.minRatio, widget.maxRatio));
    _eventSub = EventDispatcherSvc.stream.listen((event) {
      if (!mounted) return;
      if (event.type == 'split-refresh') {
        _ratio.value = PrefsSvc.desktop.getSplitRatio() ?? _ratio.value;
        setState(() {});
      } else if (event.type == 'override-split') {
        _ratio.value = event.data;
        setState(() {});
      }
    });
    debounce<double>(_ratio, (val) async {
      await PrefsSvc.desktop.setSplitRatio(val);
      EventDispatcherSvc.emit('split-refresh', null);
    });
    if (kIsWeb && GetIt.I.isRegistered<ChatsService>()) {
      _activeChatWorker = ever<String?>(ChatsSvc.activeChatGuid, (_) {
        if (NavigationSvc.showInspectorDrawer.value) {
          NavigationSvc.showInspectorDrawer.value = false;
        }
      });
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _activeChatWorker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!showAltLayout) {
      final rightOpen = widget.rightOpen;
      if (rightOpen == null) return TitleBarWrapper(child: widget.left);
      return TitleBarWrapper(
        child: Stack(
          children: [
            // Offstage alone keeps the hidden pane's animations running and its focusables reachable
            Obx(() => Offstage(
                  offstage: rightOpen.value,
                  child: TickerMode(
                    enabled: !rightOpen.value,
                    child: ExcludeFocus(excluding: rightOpen.value, child: widget.left),
                  ),
                )),
            Obx(() => IgnorePointer(ignoring: !rightOpen.value, child: widget.right)),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, BoxConstraints constraints) {
        final effectiveDividerWidth = kIsWeb ? 1.0 : widget.dividerWidth;
        _maxWidth = max(0.0, constraints.maxWidth - effectiveDividerWidth);
        final canShowInspector = widget.enableInspector && (kIsDesktop || kIsWeb) && constraints.maxWidth > 1024;
        return TitleBarWrapper(
          child: SizedBox(
            width: constraints.maxWidth,
            child: Obx(() {
              final activeGuid = canShowInspector ? ChatsSvc.activeChatGuid.value : null;
              final inspectorOpen = canShowInspector ? NavigationSvc.showInspectorDrawer.value : false;
              final activeChat = activeGuid != null ? ChatsSvc.activeChat?.chat : null;
              final hasInspectorHost = canShowInspector && activeChat != null;
              final showInspectorPane = hasInspectorHost && inspectorOpen;
              // Web collapses Details flush so no stray chevron strip remains on the right edge.
              final showCollapsedInspectorEdge = hasInspectorHost && !kIsWeb;
              final closedPanes = TabletModeWrapper.computePaneWidths(
                maxWidth: _maxWidth!,
                desiredLeftWidth: _width1,
                showInspectorPane: false,
                showInspectorToggle: showCollapsedInspectorEdge,
              );
              final openPanes = TabletModeWrapper.computePaneWidths(
                maxWidth: _maxWidth!,
                desiredLeftWidth: _width1,
                showInspectorPane: hasInspectorHost,
                showInspectorToggle: false,
              );

              void onResizeUpdate(DragUpdateDetails details) {
                if (_maxWidth == null || _maxWidth! <= 0) return;
                _ratio.value = (_ratio.value + (details.delta.dx / _maxWidth!)).clamp(widget.minRatio, widget.maxRatio);
                NavigationSvc.listener.refresh();
              }

              return TweenAnimationBuilder<double>(
                tween: Tween<double>(end: showInspectorPane ? 1.0 : 0.0),
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                child: hasInspectorHost
                    ? ChatInspectorPane(
                        key: ValueKey(activeChat.guid),
                        chat: activeChat,
                        onClose: NavigationSvc.toggleInspectorDrawer,
                      )
                    : null,
                builder: (context, t, inspectorChild) {
                  final leftWidth = hasInspectorHost
                      ? lerpDouble(closedPanes.leftWidth, openPanes.leftWidth, t)!
                      : closedPanes.leftWidth;
                  final rightWidth = hasInspectorHost
                      ? lerpDouble(closedPanes.rightWidth, openPanes.rightWidth, t)!
                      : closedPanes.rightWidth;
                  final collapsedInspectorWidth = showCollapsedInspectorEdge ? 28.0 : 0.0;
                  final inspectorWidth = hasInspectorHost ? lerpDouble(collapsedInspectorWidth, 320.0, t)! : 0.0;

                  final row = Row(
                    children: <Widget>[
                      SizedBox(
                        width: leftWidth,
                        child: widget.left,
                      ),
                      if (kIsWeb)
                        Container(
                          width: 1.0,
                          height: constraints.maxHeight,
                          color: context.theme.colorScheme.outlineVariant,
                        )
                      else if (widget.allowResize)
                        MouseRegion(
                          cursor: SystemMouseCursors.resizeLeftRight,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onPanUpdate: onResizeUpdate,
                            child: Container(
                              color: context.theme.colorScheme.surfaceContainerHighest,
                              width: widget.dividerWidth,
                              height: constraints.maxHeight,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                      height: 4,
                                      width: 4,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(25),
                                        color: context.theme.colorScheme.onSurfaceVariant,
                                      )),
                                  const SizedBox(height: 20),
                                  Container(
                                      height: 4,
                                      width: 4,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(25),
                                        color: context.theme.colorScheme.onSurfaceVariant,
                                      )),
                                  const SizedBox(height: 20),
                                  Container(
                                      height: 4,
                                      width: 4,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(25),
                                        color: context.theme.colorScheme.onSurfaceVariant,
                                      )),
                                ],
                              ),
                            ),
                          ),
                        )
                      else
                        Container(
                            width: widget.dividerWidth,
                            height: constraints.maxHeight,
                            color: context.theme.colorScheme.surfaceContainerHighest),
                      SizedBox(
                        width: rightWidth,
                        child: widget.right,
                      ),
                      if (hasInspectorHost && (showCollapsedInspectorEdge || t > 0.001)) ...[
                        SizedBox(
                          width: showCollapsedInspectorEdge ? 1.0 : t.clamp(0.0, 1.0),
                          height: constraints.maxHeight,
                          child: ColoredBox(
                            color: context.theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                          ),
                        ),
                        SizedBox(
                          width: inspectorWidth,
                          height: constraints.maxHeight,
                          child: ClipRect(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (showCollapsedInspectorEdge && t < 0.999)
                                  Opacity(
                                    opacity: (1.0 - t * 4.0).clamp(0.0, 1.0),
                                    child: Material(
                                      color: context.theme.colorScheme.surface,
                                      child: Align(
                                        alignment: Alignment.topCenter,
                                        child: Padding(
                                          padding: const EdgeInsets.only(top: 10),
                                          child: IconButton(
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                                            tooltip: 'Show chat details (Alt+I)',
                                            icon: Icon(
                                              Icons.chevron_left_rounded,
                                              size: 18,
                                              color: context.theme.colorScheme.onSurfaceVariant,
                                            ),
                                            onPressed: t < 0.2 ? NavigationSvc.toggleInspectorDrawer : null,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                if (t > 0.001 && inspectorChild != null)
                                  OverflowBox(
                                    alignment: Alignment.topLeft,
                                    minWidth: 320,
                                    maxWidth: 320,
                                    minHeight: constraints.maxHeight,
                                    maxHeight: constraints.maxHeight,
                                    child: FractionalTranslation(
                                      translation: Offset((1.0 - t) * 0.14, 0.0),
                                      child: Opacity(
                                        opacity: t.clamp(0.0, 1.0),
                                        child: IgnorePointer(
                                          ignoring: t < 0.5 && !showInspectorPane,
                                          child: inspectorChild,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  );

                  if (!kIsWeb || !widget.allowResize) return row;
                  return Stack(
                    children: [
                      row,
                      Positioned(
                        left: max(0.0, leftWidth - 3.0),
                        top: 0,
                        bottom: 0,
                        width: 7.0,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeLeftRight,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onPanUpdate: onResizeUpdate,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            }),
          ),
        );
      },
    );
  }
}
