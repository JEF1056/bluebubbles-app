import 'package:flutter/material.dart';

enum TitleBarStyle { normal, hidden }

Future<Offset> calcWindowPosition(Size windowSize, Alignment alignment) async => Offset.zero;

class WindowManager {
  Future<void> ensureInitialized() async {}
  Future<void> setTitleBarStyle(TitleBarStyle titleBarStyle) async {}
  Future<void> setPreventClose(bool isPreventClose) async {}
  Future<bool> isPreventClose() async => false;
  Future<void> setTitle(String title) async {}
  void addListener(WindowListener listener) {}
  void removeListener(WindowListener listener) {}
  Future<void> setMinimumSize(Size size) async {}
  Future<void> setSize(Size size) async {}
  Future<Size> getSize() async => Size.zero;
  Future<Offset> getPosition() async => Offset.zero;
  Future<void> setBounds(Rect bounds) async {}
  Future<void> show() async {}
  Future<void> hide() async {}
  Future<void> minimize() async {}
  Future<void> close() async {}
  Future<bool> isMinimized() async => false;
  Future<void> restore() async {}
  Future<void> focus() async {}
}

final WindowManager windowManager = WindowManager();

abstract class WindowListener {
  void onWindowClose() {}
  void onWindowFocus() {}
  void onWindowBlur() {}
  void onWindowMaximize() {}
  void onWindowUnmaximize() {}
  void onWindowMinimize() {}
  void onWindowRestore() {}
  void onWindowResize() {}
  void onWindowMove() {}
}

class AppWindow {
  double get titleBarHeight => 0;
  Size get titleBarButtonSize => Size.zero;
  bool get isVisible => true;
}

final AppWindow appWindow = AppWindow();

void doWhenWindowReady(VoidCallback callback) {}

class WindowTitleBarBox extends StatelessWidget {
  final Widget? child;
  const WindowTitleBarBox({super.key, this.child});
  @override
  Widget build(BuildContext context) => child ?? const SizedBox.shrink();
}

class WindowBorder extends StatelessWidget {
  final Widget child;
  final Color color;
  final double? width;
  const WindowBorder({super.key, required this.child, required this.color, this.width});
  @override
  Widget build(BuildContext context) => child;
}

class MoveWindow extends StatelessWidget {
  final Widget? child;
  const MoveWindow({super.key, this.child});
  @override
  Widget build(BuildContext context) => child ?? const SizedBox.shrink();
}

class WindowButtonColors {
  final Color? iconNormal;
  final Color? mouseOver;
  final Color? mouseDown;
  final Color? iconMouseOver;
  final Color? iconMouseDown;
  WindowButtonColors({
    this.iconNormal,
    this.mouseOver,
    this.mouseDown,
    this.iconMouseOver,
    this.iconMouseDown,
  });
}

class MinimizeWindowButton extends StatelessWidget {
  final WindowButtonColors? colors;
  final VoidCallback? onPressed;
  final bool animate;
  const MinimizeWindowButton({super.key, this.colors, this.onPressed, this.animate = false});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class MaximizeWindowButton extends StatelessWidget {
  final WindowButtonColors? colors;
  final VoidCallback? onPressed;
  final bool animate;
  const MaximizeWindowButton({super.key, this.colors, this.onPressed, this.animate = false});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class CloseWindowButton extends StatelessWidget {
  final WindowButtonColors? colors;
  final VoidCallback? onPressed;
  final bool animate;
  const CloseWindowButton({super.key, this.colors, this.onPressed, this.animate = false});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

enum ContextMenuTrigger { rightClicked }
enum MenuItemType { normal }

class ImageAsset {
  static ImageAsset? fromAsset(String path) => null;
}

class TrayIconClickedEvent {}
class MenuItemClickedEvent {}

class MenuItem {
  String label = '';
  static MenuItem? createWithLabelAndType(String label, MenuItemType type) => null;
  void addListener(void Function(Object event) listener) {}
}

class Menu {
  static Menu? create() => null;
  void addItem(MenuItem item) {}
  void addSeparator() {}
}

class TrayIcon {
  ImageAsset? icon;
  static TrayIcon? create() => null;
  void setTooltip(String tooltip) {}
  void setContextMenuTrigger(ContextMenuTrigger trigger) {}
  void addListener(void Function(Object event) listener) {}
  void setContextMenu(Menu menu) {}
  void setVisible(bool visible) {}
}

enum TaskbarProgressMode { noProgress, indeterminate, normal, error }
enum TaskbarFlashMode { timernofg }

class ThumbnailToolbarAssetIcon {
  const ThumbnailToolbarAssetIcon(String path);
}

class WindowsTaskbar {
  static Future<void> resetOverlayIcon() async {}
  static Future<void> setOverlayIcon(ThumbnailToolbarAssetIcon icon) async {}
  static Future<void> setProgressMode(TaskbarProgressMode mode) async {}
  static Future<void> setProgress(int completed, int total) async {}
  static Future<void> setFlashTaskbarAppIcon({required TaskbarFlashMode mode}) async {}
}
