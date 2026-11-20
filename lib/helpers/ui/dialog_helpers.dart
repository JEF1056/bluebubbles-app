import 'dart:ui' show ImageFilter;

import 'package:bluebubbles/app/components/custom/custom_cupertino_alert_dialog.dart';
import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/helpers/types/helpers/misc_helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart' hide CupertinoAlertDialog, CupertinoDialogAction;
import 'package:flutter/material.dart';

/// A single action button for use in [showBBDialog], [showBBBottomSheet], and [BBProgressDialog].
class BBDialogAction {
  final String text;
  final VoidCallback? onPressed;

  /// Marks the action as destructive (red on iOS, error styling on Material/Samsung).
  final bool isDestructive;

  /// Marks the action as the primary/default CTA (bold on iOS, filled pill on Material/Samsung).
  final bool isDefault;

  /// Material/Samsung skin only — overrides the button foreground (or fill when [isDefault]) color.
  final Color? color;

  /// Material/Samsung skin only — renders as a tonal pill when neither [isDefault] nor [isDestructive].
  final bool isTonal;

  const BBDialogAction({
    required this.text,
    this.onPressed,
    this.isDestructive = false,
    this.isDefault = false,
    this.color,
    this.isTonal = false,
  });
}

bool _isIOSSkin() => SettingsSvc.settings.skin.value == Skins.iOS;

CupertinoThemeData _iosCupertinoTheme(BuildContext ctx) => CupertinoThemeData(
      brightness: Theme.of(ctx).brightness,
      primaryColor: ctx.colorScheme.primary,
    );

Color _iosFrostedColor(BuildContext ctx) {
  final isDark = Theme.of(ctx).brightness == Brightness.dark;
  return ctx.colorScheme.surfaceContainerHighest.withValues(alpha: isDark ? 0.76 : 0.82);
}

Widget _iosHairlineDivider(BuildContext ctx) => Container(
      height: 0.5,
      color: CupertinoDynamicColor.resolve(CupertinoColors.separator, ctx),
    );

Widget _buildM3IconBadge(BuildContext ctx, IconData icon, {Color? color}) {
  final tint = color ?? ctx.colorScheme.primary;
  return Container(
    width: 48,
    height: 48,
    decoration: BoxDecoration(
      color: tint.withValues(alpha: 0.12),
      shape: BoxShape.circle,
    ),
    child: Icon(icon, size: 24, color: tint),
  );
}

Widget _buildM3Action(BuildContext ctx, BBDialogAction a) {
  const minSize = Size(48, 48);
  const padding = EdgeInsets.symmetric(horizontal: 20, vertical: 12);
  const shape = StadiumBorder();

  if (a.isDefault) {
    final bg = a.isDestructive ? ctx.colorScheme.error : (a.color ?? ctx.colorScheme.primary);
    final Color fg;
    if (a.isDestructive || a.color == ctx.colorScheme.error) {
      fg = ctx.colorScheme.onError;
    } else if (a.color != null) {
      fg = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark ? Colors.white : Colors.black;
    } else {
      fg = ctx.colorScheme.onPrimary;
    }
    return FilledButton(
      onPressed: a.onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        minimumSize: minSize,
        padding: padding,
        shape: shape,
      ),
      child: Text(a.text),
    );
  }

  if (a.isDestructive) {
    return FilledButton.tonal(
      onPressed: a.onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: ctx.colorScheme.errorContainer,
        foregroundColor: ctx.colorScheme.onErrorContainer,
        minimumSize: minSize,
        padding: padding,
        shape: shape,
      ),
      child: Text(a.text),
    );
  }

  if (a.isTonal) {
    return FilledButton.tonal(
      onPressed: a.onPressed,
      style: FilledButton.styleFrom(
        foregroundColor: a.color ?? ctx.colorScheme.onSecondaryContainer,
        minimumSize: minSize,
        padding: padding,
        shape: shape,
      ),
      child: Text(a.text),
    );
  }

  return TextButton(
    onPressed: a.onPressed,
    style: TextButton.styleFrom(
      foregroundColor: a.color ?? ctx.colorScheme.primary,
      minimumSize: minSize,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      shape: shape,
    ),
    child: Text(a.text),
  );
}

Future<T?> _showAnimatedDialog<T>({
  required BuildContext context,
  required bool barrierDismissible,
  required bool useRootNavigator,
  required WidgetBuilder builder,
}) {
  final disableAnimations = MediaQuery.disableAnimationsOf(context);
  final themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: useRootNavigator).context,
  );

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    useRootNavigator: useRootNavigator,
    transitionDuration: disableAnimations ? Duration.zero : const Duration(milliseconds: 180),
    pageBuilder: (ctx, _, _) => themes.wrap(builder(ctx)),
    transitionBuilder: (ctx, animation, _, child) {
      if (disableAnimations) return child;
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Shows a skin-aware dialog with crisp fade+scale transitions honoring [MediaQuery.disableAnimations].
///
/// On the iOS skin this renders a frosted-glass [CupertinoAlertDialog]; on
/// Material and Samsung skins it renders an M3 Expressive tonal [AlertDialog]
/// with 28dp rounded surfaces, 24dp edges, optional [icon] badge, and pill CTAs.
Future<T?> showBBDialog<T>({
  required BuildContext context,
  String? title,
  Widget? content,
  String? body,
  List<BBDialogAction> actions = const [],
  bool barrierDismissible = true,
  bool useRootNavigator = true,
  TextAlign? bodyTextAlign,
  IconData? icon,
  Color? iconColor,
}) {
  final rawBodyWidget = content ?? (body != null ? Text(body, textAlign: bodyTextAlign) : null);
  final bodyWidget = bodyTextAlign != null && rawBodyWidget != null
      ? DefaultTextStyle.merge(textAlign: bodyTextAlign, child: rawBodyWidget)
      : rawBodyWidget;

  return _showAnimatedDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    useRootNavigator: useRootNavigator,
    builder: (ctx) => _buildBBDialogSurface(
      ctx,
      title: title,
      bodyWidget: bodyWidget,
      actions: actions,
      icon: icon,
      iconColor: iconColor,
    ),
  );
}

Widget _buildBBDialogSurface(
  BuildContext ctx, {
  String? title,
  Widget? bodyWidget,
  List<BBDialogAction> actions = const [],
  IconData? icon,
  Color? iconColor,
}) {
  if (_isIOSSkin()) {
    return CupertinoTheme(
      data: _iosCupertinoTheme(ctx),
      child: CupertinoAlertDialog(
        backgroundColor: _iosFrostedColor(ctx),
        title: (icon != null || title != null)
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null)
                    Padding(
                      padding: EdgeInsets.only(bottom: title != null ? 8 : 0),
                      child: Icon(icon, size: 28, color: iconColor ?? ctx.colorScheme.primary),
                    ),
                  if (title != null) Text(title),
                ],
              )
            : null,
        content: bodyWidget != null ? Material(type: MaterialType.transparency, child: bodyWidget) : null,
        actions: actions
            .map(
              (a) => CupertinoDialogAction(
                isDestructiveAction: a.isDestructive,
                isDefaultAction: a.isDefault,
                onPressed: a.onPressed,
                child: Text(a.text),
              ),
            )
            .toList(),
      ),
    );
  }

  return AlertDialog(
    backgroundColor: ctx.colorScheme.surfaceContainerHigh,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    icon: icon != null ? _buildM3IconBadge(ctx, icon, color: iconColor) : null,
    iconPadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
    titlePadding: EdgeInsets.fromLTRB(24, icon != null ? 16 : 24, 24, 0),
    contentPadding: EdgeInsets.fromLTRB(24, (title != null || icon != null) ? 12 : 24, 24, actions.isEmpty ? 24 : 8),
    actionsPadding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
    title: title != null
        ? Text(
            title,
            style: ctx.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
            textAlign: icon != null ? TextAlign.center : null,
          )
        : null,
    content: bodyWidget,
    actions: actions.map((a) => _buildM3Action(ctx, a)).toList(),
  );
}

/// Convenience wrapper around [showBBDialog] for simple yes/no confirmation dialogs.
Future<void> showAreYouSure(
  BuildContext context, {
  Widget? content,
  String? title = "Are you sure?",
  String? noText = "No",
  String? yesText = "Yes",
  Color? noColor,
  Color? yesColor,
  bool yesIsDestructive = false,
  TextAlign textAlign = TextAlign.center,
  required Function onNo,
  required Function onYes,
  bool barrierDismissible = true,
  IconData? icon,
}) {
  return showBBDialog(
    context: context,
    title: title,
    content: content,
    bodyTextAlign: textAlign,
    barrierDismissible: barrierDismissible,
    icon: icon,
    iconColor: yesIsDestructive ? context.colorScheme.error : null,
    actions: [
      BBDialogAction(
        text: noText ?? "No",
        color: noColor,
        onPressed: () => onNo.call(),
      ),
      BBDialogAction(
        text: yesText ?? "Yes",
        color: yesColor,
        isDestructive: yesIsDestructive,
        isDefault: true,
        onPressed: () => onYes.call(),
      ),
    ],
  );
}

/// A single selectable option for [showBBListSelector].
class BBListSelectorOption<T> {
  final String label;
  final T value;

  /// Renders the option in destructive/error styling.
  final bool isDestructive;

  /// Optional leading icon for Material/Samsung rows.
  final IconData? icon;

  const BBListSelectorOption({
    required this.label,
    required this.value,
    this.isDestructive = false,
    this.icon,
  });
}

/// Controls how [showBBListSelector] presents its options on the iOS skin.
/// Ignored on Material/Samsung, which always render as a scrollable list.
enum BBListSelectorIOSStyle {
  actionSheet,
  wheel,
}

/// Shows a skin-aware single-selection list dialog or iOS action sheet/wheel.
Future<T?> showBBListSelector<T>({
  required BuildContext context,
  String? title,
  String? message,
  required List<BBListSelectorOption<T>> options,
  BBListSelectorIOSStyle iosStyle = BBListSelectorIOSStyle.actionSheet,
  String cancelText = "Cancel",
}) {
  if (_isIOSSkin()) {
    return iosStyle == BBListSelectorIOSStyle.wheel
        ? _showCupertinoWheelSelector<T>(context, title: title, options: options, cancelText: cancelText)
        : _showCupertinoActionSheetSelector<T>(
            context,
            title: title,
            message: message,
            options: options,
            cancelText: cancelText,
          );
  }

  // Material / Samsung
  return showBBDialog<T>(
    context: context,
    title: title,
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(message, style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant)),
            ),
          ...options.map((option) {
            final fg = option.isDestructive ? context.colorScheme.error : context.colorScheme.onSurface;
            return ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                leading: option.icon != null ? Icon(option.icon, color: fg) : null,
                title: Text(option.label, style: context.textTheme.bodyLarge?.copyWith(color: fg)),
                onTap: () => Navigator.of(context, rootNavigator: true).pop(option.value),
              ),
            );
          }),
        ],
      ),
    ),
    actions: [
      BBDialogAction(text: cancelText, onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
    ],
  );
}

Future<T?> _showCupertinoActionSheetSelector<T>(
  BuildContext context, {
  String? title,
  String? message,
  required List<BBListSelectorOption<T>> options,
  required String cancelText,
}) {
  final cupertinoTheme = _iosCupertinoTheme(context);
  return showCupertinoModalPopup<T>(
    context: context,
    builder: (ctx) => CupertinoTheme(
      data: cupertinoTheme,
      child: CupertinoActionSheet(
        title: title != null ? Text(title) : null,
        message: message != null ? Text(message) : null,
        actions: options.map((option) {
          return CupertinoActionSheetAction(
            isDestructiveAction: option.isDestructive,
            onPressed: () => Navigator.of(ctx).pop(option.value),
            child: Text(option.label),
          );
        }).toList(),
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(cancelText),
        ),
      ),
    ),
  );
}

Future<T?> _showWheelModal<T>({
  required BuildContext context,
  required Widget child,
  required T Function() onDone,
  String? title,
  String cancelText = "Cancel",
  double height = 260,
}) {
  final cupertinoTheme = _iosCupertinoTheme(context);
  final disableAnimations = MediaQuery.disableAnimationsOf(context);
  final themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: true).context,
  );

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black38,
    useRootNavigator: true,
    transitionDuration: disableAnimations ? Duration.zero : const Duration(milliseconds: 220),
    pageBuilder: (ctx, _, _) => themes.wrap(
      Align(
        alignment: Alignment.bottomCenter,
        child: CupertinoTheme(
          data: cupertinoTheme,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                height: height,
                color: _iosFrostedColor(ctx),
                child: SafeArea(
                  top: false,
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          CupertinoButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: Text(cancelText),
                          ),
                          if (title != null) Text(title, style: cupertinoTheme.textTheme.navTitleTextStyle),
                          CupertinoButton(
                            onPressed: () => Navigator.of(ctx).pop(onDone()),
                            child: const Text("Done", style: TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      _iosHairlineDivider(ctx),
                      Expanded(child: child),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (ctx, animation, _, modal) {
      if (disableAnimations) return modal;
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
      return SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(curved),
        child: modal,
      );
    },
  );
}

/// Shows a skin-aware date + time picker.
Future<DateTime?> showBBDateTimePicker({
  required BuildContext context,
  DateTime? initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
}) async {
  final first = firstDate ?? DateTime.now();
  final last = lastDate ?? first.add(const Duration(days: 365 * 5));
  final initial = (initialDate?.isAfter(first) ?? false) ? initialDate! : first.add(const Duration(minutes: 1));

  if (_isIOSSkin()) {
    var picked = initial;
    return _showWheelModal<DateTime>(
      context: context,
      height: 300,
      onDone: () => picked,
      child: CupertinoDatePicker(
        initialDateTime: initial,
        minimumDate: first,
        maximumDate: last,
        mode: CupertinoDatePickerMode.dateAndTime,
        onDateTimeChanged: (dt) => picked = dt,
      ),
    );
  }

  final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      initialEntryMode: kIsDesktop ? DatePickerEntryMode.input : DatePickerEntryMode.calendar);
  if (date == null || !context.mounted) return null;

  final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      initialEntryMode: kIsDesktop ? TimePickerEntryMode.input : TimePickerEntryMode.dial);
  if (time == null) return null;

  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

Future<T?> _showCupertinoWheelSelector<T>(
  BuildContext context, {
  String? title,
  required List<BBListSelectorOption<T>> options,
  required String cancelText,
}) {
  var selectedIndex = 0;
  return _showWheelModal<T>(
    context: context,
    title: title,
    cancelText: cancelText,
    onDone: () => options[selectedIndex].value,
    child: CupertinoPicker(
      itemExtent: 36,
      onSelectedItemChanged: (index) => selectedIndex = index,
      children: options.map((o) => Center(child: Text(o.label))).toList(),
    ),
  );
}

/// A skin-aware dialog for showing the progress of a long-running operation.
class BBProgressDialog extends StatelessWidget {
  const BBProgressDialog({
    super.key,
    required this.title,
    this.progress,
    this.body,
    this.actions = const [],
  });

  final String title;
  final double? progress;
  final Widget? body;
  final List<BBDialogAction> actions;

  @override
  Widget build(BuildContext context) {
    if (_isIOSSkin()) {
      return CupertinoTheme(
        data: _iosCupertinoTheme(context),
        child: CupertinoAlertDialog(
          backgroundColor: _iosFrostedColor(context),
          title: Text(title),
          content: Material(
            type: MaterialType.transparency,
            child: body ?? _CupertinoProgressIndicator(value: progress),
          ),
          actions: actions
              .map(
                (a) => CupertinoDialogAction(
                  isDestructiveAction: a.isDestructive,
                  isDefaultAction: a.isDefault,
                  onPressed: a.onPressed,
                  child: Text(a.text),
                ),
              )
              .toList(),
        ),
      );
    }

    // Material / Samsung (M3 Expressive)
    return AlertDialog(
      backgroundColor: context.colorScheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      title: Text(title, style: context.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
      content: body ??
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 6,
              value: progress,
              backgroundColor: context.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(context.colorScheme.primary),
            ),
          ),
      actions: actions.map((a) => _buildM3Action(context, a)).toList(),
    );
  }
}

class _CupertinoProgressIndicator extends StatelessWidget {
  const _CupertinoProgressIndicator({this.value});

  final double? value;

  @override
  Widget build(BuildContext context) {
    if (value == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: CupertinoActivityIndicator(),
      );
    }

    final activeColor = CupertinoTheme.of(context).primaryColor;
    final trackColor = CupertinoDynamicColor.resolve(CupertinoColors.systemFill, context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          height: 4,
          child: LinearProgressIndicator(
            value: value,
            backgroundColor: trackColor,
            valueColor: AlwaysStoppedAnimation<Color>(activeColor),
          ),
        ),
      ),
    );
  }
}

/// Shows a skin-aware modal bottom sheet.
///
/// On Material/Samsung this renders an M3 Expressive 28dp tonal surface with a
/// drag handle, 24dp horizontal edges, optional [icon] badge + [title]/[subtitle],
/// and pill CTA [actions]. On iOS it renders a slide-up frosted-glass
/// [BackdropFilter] sheet with a capsule grabber and hairline header divider.
///
/// Supply either [child] or [builder] (`builder` receives the sheet's [BuildContext]).
Future<T?> showBBBottomSheet<T>({
  required BuildContext context,
  String? title,
  String? subtitle,
  IconData? icon,
  Color? iconColor,
  Widget? child,
  WidgetBuilder? builder,
  Widget Function(BuildContext context, ScrollController scrollController)? scrollableBuilder,
  double initialChildSize = 0.6,
  double minChildSize = 0.25,
  double maxChildSize = 0.92,
  List<double>? snapSizes,
  List<BBDialogAction> actions = const [],
  bool isScrollControlled = true,
  bool isDismissible = true,
  bool enableDrag = true,
  bool showDragHandle = true,
  bool useRootNavigator = true,
  bool useSafeArea = true,
  EdgeInsetsGeometry? padding,
}) {
  assert(
    child != null || builder != null || scrollableBuilder != null,
    'Provide either child, builder, or scrollableBuilder',
  );
  final disableAnimations = MediaQuery.disableAnimationsOf(context);

  if (_isIOSSkin()) {
    final cupertinoTheme = _iosCupertinoTheme(context);

    Widget buildIosHeader(BuildContext ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showDragHandle)
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 6),
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: CupertinoDynamicColor.resolve(CupertinoColors.tertiaryLabel, ctx),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),
            if (title != null || subtitle != null || icon != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 22, color: iconColor ?? ctx.colorScheme.primary),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (title != null)
                            Text(title, style: ctx.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                          if (subtitle != null)
                            Text(
                              subtitle,
                              style: ctx.textTheme.bodySmall?.copyWith(color: ctx.colorScheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _iosHairlineDivider(ctx),
            ],
          ],
        );

    Widget buildIosActions(BuildContext ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _iosHairlineDivider(ctx),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: actions
                    .map(
                      (a) => CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        onPressed: a.onPressed,
                        child: Text(
                          a.text,
                          style: TextStyle(
                            fontWeight: a.isDefault ? FontWeight.w600 : FontWeight.w400,
                            color: a.isDestructive ? CupertinoColors.destructiveRed : null,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        );

    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      isScrollControlled: isScrollControlled,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      useSafeArea: useSafeArea,
      backgroundColor: Colors.transparent,
      elevation: 0,
      barrierColor: Colors.black38,
      sheetAnimationStyle: disableAnimations
          ? AnimationStyle.noAnimation
          : const AnimationStyle(duration: Duration(milliseconds: 240), reverseDuration: Duration(milliseconds: 180)),
      builder: (ctx) {
        Widget wrapIosSurface(BuildContext sCtx, Widget body) => CupertinoTheme(
              data: cupertinoTheme,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Material(
                    color: _iosFrostedColor(sCtx),
                    child: SizedBox(width: double.infinity, child: body),
                  ),
                ),
              ),
            );

        if (scrollableBuilder != null) {
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: initialChildSize,
              minChildSize: minChildSize,
              maxChildSize: maxChildSize,
              snap: true,
              snapSizes: snapSizes ?? [initialChildSize],
              builder: (sheetCtx, scrollController) => wrapIosSurface(
                sheetCtx,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    buildIosHeader(sheetCtx),
                    Expanded(
                      child: Padding(
                        padding: padding ?? EdgeInsets.zero,
                        child: scrollableBuilder(sheetCtx, scrollController),
                      ),
                    ),
                    if (actions.isNotEmpty)
                      useSafeArea
                          ? SafeArea(top: false, child: buildIosActions(sheetCtx))
                          : buildIosActions(sheetCtx),
                  ],
                ),
              ),
            ),
          );
        }

        final contentColumn = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            buildIosHeader(ctx),
            Flexible(
              child: Padding(
                padding: padding ?? const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: builder?.call(ctx) ?? child!,
              ),
            ),
            if (actions.isNotEmpty) buildIosActions(ctx),
          ],
        );

        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: wrapIosSurface(
            ctx,
            useSafeArea ? SafeArea(top: false, child: contentColumn) : contentColumn,
          ),
        );
      },
    );
  }

  // Material / Samsung (M3 Expressive)
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useSafeArea: useSafeArea,
    backgroundColor: scrollableBuilder != null ? Colors.transparent : context.colorScheme.surfaceContainerHigh,
    elevation: scrollableBuilder != null ? 0 : null,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    sheetAnimationStyle: disableAnimations
        ? AnimationStyle.noAnimation
        : const AnimationStyle(duration: Duration(milliseconds: 240), reverseDuration: Duration(milliseconds: 180)),
    builder: (ctx) {
      Widget buildM3Header(BuildContext sCtx) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showDragHandle)
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: sCtx.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              if (title != null || subtitle != null || icon != null)
                Padding(
                  padding: EdgeInsets.fromLTRB(24, showDragHandle ? 8 : 24, 24, 8),
                  child: Row(
                    children: [
                      if (icon != null) ...[
                        _buildM3IconBadge(sCtx, icon, color: iconColor),
                        const SizedBox(width: 16),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (title != null)
                              Text(title, style: sCtx.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                            if (subtitle != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  subtitle,
                                  style: sCtx.textTheme.bodyMedium?.copyWith(color: sCtx.colorScheme.onSurfaceVariant),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );

      Widget buildM3Actions(BuildContext sCtx) => Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: actions.map((a) => _buildM3Action(sCtx, a)).toList(),
            ),
          );

      if (scrollableBuilder != null) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: initialChildSize,
            minChildSize: minChildSize,
            maxChildSize: maxChildSize,
            snap: true,
            snapSizes: snapSizes ?? [initialChildSize],
            builder: (sheetCtx, scrollController) => Material(
              color: sheetCtx.colorScheme.surfaceContainerHigh,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  buildM3Header(sheetCtx),
                  Expanded(
                    child: Padding(
                      padding: padding ?? EdgeInsets.zero,
                      child: scrollableBuilder(sheetCtx, scrollController),
                    ),
                  ),
                  if (actions.isNotEmpty)
                    useSafeArea
                        ? SafeArea(top: false, child: buildM3Actions(sheetCtx))
                        : buildM3Actions(sheetCtx),
                ],
              ),
            ),
          ),
        );
      }

      final sheetBody = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          buildM3Header(ctx),
          Flexible(
            child: Padding(
              padding: padding ?? const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: builder?.call(ctx) ?? child!,
            ),
          ),
          if (actions.isNotEmpty) buildM3Actions(ctx),
        ],
      );

      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: useSafeArea ? SafeArea(top: false, child: sheetBody) : sheetBody,
      );
    },
  );
}

/// Shows a skin-aware text input dialog and returns the submitted string, or
/// `null` if cancelled/dismissed.
Future<String?> showBBInputDialog({
  required BuildContext context,
  String? title,
  String? body,
  String? initialValue,
  String? hintText,
  String? labelText,
  String confirmText = "Save",
  String cancelText = "Cancel",
  IconData? icon,
  Color? iconColor,
  TextInputType? keyboardType,
  TextCapitalization textCapitalization = TextCapitalization.none,
  bool obscureText = false,
  int? maxLines = 1,
  int? maxLength,
  String? Function(String?)? validator,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
}) {
  return _showAnimatedDialog<String>(
    context: context,
    barrierDismissible: barrierDismissible,
    useRootNavigator: useRootNavigator,
    builder: (ctx) => _BBInputDialog(
      title: title,
      body: body,
      initialValue: initialValue,
      hintText: hintText,
      labelText: labelText,
      confirmText: confirmText,
      cancelText: cancelText,
      icon: icon,
      iconColor: iconColor,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      obscureText: obscureText,
      maxLines: maxLines,
      maxLength: maxLength,
      validator: validator,
      useRootNavigator: useRootNavigator,
    ),
  );
}

class _BBInputDialog extends StatefulWidget {
  const _BBInputDialog({
    this.title,
    this.body,
    this.initialValue,
    this.hintText,
    this.labelText,
    required this.confirmText,
    required this.cancelText,
    this.icon,
    this.iconColor,
    this.keyboardType,
    required this.textCapitalization,
    required this.obscureText,
    this.maxLines,
    this.maxLength,
    this.validator,
    required this.useRootNavigator,
  });

  final String? title;
  final String? body;
  final String? initialValue;
  final String? hintText;
  final String? labelText;
  final String confirmText;
  final String cancelText;
  final IconData? icon;
  final Color? iconColor;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final bool obscureText;
  final int? maxLines;
  final int? maxLength;
  final String? Function(String?)? validator;
  final bool useRootNavigator;

  @override
  State<_BBInputDialog> createState() => _BBInputDialogState();
}

class _BBInputDialogState extends State<_BBInputDialog> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final err = widget.validator?.call(_controller.text);
    if (err != null) {
      setState(() => _errorText = err);
      return;
    }
    Navigator.of(context, rootNavigator: widget.useRootNavigator).pop(_controller.text);
  }

  void _cancel() {
    Navigator.of(context, rootNavigator: widget.useRootNavigator).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isIOS = _isIOSSkin();
    final contentWidget = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.body != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(widget.body!, style: context.textTheme.bodyMedium),
          ),
        if (isIOS)
          CupertinoTextField(
            controller: _controller,
            autofocus: true,
            placeholder: widget.hintText ?? widget.labelText,
            keyboardType: widget.keyboardType,
            textCapitalization: widget.textCapitalization,
            obscureText: widget.obscureText,
            maxLines: widget.maxLines,
            maxLength: widget.maxLength,
            clearButtonMode: OverlayVisibilityMode.editing,
            onSubmitted: (_) => _submit(),
            onChanged: (_) {
              if (_errorText != null) setState(() => _errorText = null);
            },
          )
        else
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: widget.keyboardType,
            textCapitalization: widget.textCapitalization,
            obscureText: widget.obscureText,
            maxLines: widget.maxLines,
            maxLength: widget.maxLength,
            onSubmitted: (_) => _submit(),
            onChanged: (_) {
              if (_errorText != null) setState(() => _errorText = null);
            },
            decoration: InputDecoration(
              hintText: widget.hintText,
              labelText: widget.labelText,
              errorText: _errorText,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
        if (isIOS && _errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _errorText!,
              style: const TextStyle(color: CupertinoColors.destructiveRed, fontSize: 12),
            ),
          ),
      ],
    );

    return _buildBBDialogSurface(
      context,
      title: widget.title,
      icon: widget.icon,
      iconColor: widget.iconColor,
      bodyWidget: contentWidget,
      actions: [
        BBDialogAction(text: widget.cancelText, onPressed: _cancel),
        BBDialogAction(text: widget.confirmText, isDefault: true, onPressed: _submit),
      ],
    );
  }
}

extension _ContextTheme on BuildContext {
  TextTheme get textTheme => Theme.of(this).textTheme;
  ColorScheme get colorScheme => Theme.of(this).colorScheme;
}
