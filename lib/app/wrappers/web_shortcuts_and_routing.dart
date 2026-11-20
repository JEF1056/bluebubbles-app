import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ToggleInspectorIntent extends Intent {
  const ToggleInspectorIntent();
}

class ShowKeyboardShortcutsIntent extends Intent {
  const ShowKeyboardShortcutsIntent();
}

String? pushWebHashRoute({
  required bool syncingFromUrl,
  required String? lastPushedHashPath,
  bool replace = false,
}) {
  if (!kIsWeb || syncingFromUrl || !SettingsSvc.settings.finishedSetup.value) {
    return lastPushedHashPath;
  }
  final uri = buildWebHashRouteUri(
    settingsOpen: NavigationSvc.isSettingsOpen.value,
    activeChatGuid: ChatsSvc.activeChatGuid.value,
  );
  if (lastPushedHashPath == uri.path) return lastPushedHashPath;
  SystemNavigator.routeInformationUpdated(uri: uri, replace: replace);
  return uri.path;
}

void showKeyboardShortcutsDialog(BuildContext context) {
  final navContext = NavigationSvc.key.currentContext ?? context;
  if (!navContext.mounted) return;
  showDialog<void>(
    context: navContext,
    builder: (dlgContext) {
      final cs = Theme.of(dlgContext).colorScheme;
      final tt = Theme.of(dlgContext).textTheme;
      Widget row(String keys, String label) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Expanded(child: Text(label, style: tt.bodyMedium)),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    keys,
                    style: tt.labelSmall?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface),
                  ),
                ),
              ],
            ),
          );
      return AlertDialog(
        title: const Text('Keyboard shortcuts'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SingleChildScrollView(
            child: LayoutBuilder(
              builder: (_, constraints) {
                final twoCol = constraints.maxWidth >= 460;
                final navCol = Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Navigation', style: tt.titleSmall?.copyWith(color: cs.primary)),
                    const SizedBox(height: 8),
                    row('Ctrl/Cmd + K', 'New conversation'),
                    row('Ctrl + . / Ctrl + Tab', 'Next conversation'),
                    row(
                      kIsWeb ? 'Ctrl + , / Ctrl + Shift + Tab' : 'Ctrl + Shift + Tab',
                      'Previous conversation',
                    ),
                    row('Ctrl/Cmd + F', 'Search messages'),
                  ],
                );
                final actCol = Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Messaging & Actions', style: tt.titleSmall?.copyWith(color: cs.primary)),
                    const SizedBox(height: 8),
                    row('Alt + R', 'Reply to recent message'),
                    row('Alt + I', 'Toggle chat details'),
                    row('Alt + ,', 'Open settings'),
                    row('Ctrl/Cmd + /', 'Show keyboard shortcuts'),
                    row('Esc', 'Close / Go back'),
                  ],
                );
                if (!twoCol) {
                  return Column(mainAxisSize: MainAxisSize.min, children: [navCol, const SizedBox(height: 16), actCol]);
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: navCol),
                    const SizedBox(width: 24),
                    Expanded(child: actCol),
                  ],
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dlgContext).pop(), child: const Text('Close')),
        ],
      );
    },
  );
}
