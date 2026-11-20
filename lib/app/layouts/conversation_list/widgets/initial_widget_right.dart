import 'package:bluebubbles/app/layouts/chat_creator/new_chat_creator.dart';
import 'package:bluebubbles/platform/shims/window_effect.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class InitialWidgetRight extends StatefulWidget {
  const InitialWidgetRight({super.key});

  @override
  State<StatefulWidget> createState() => _InitialWidgetRightState();
}

class _InitialWidgetRightState extends State<InitialWidgetRight> {
  @override
  Widget build(BuildContext context) {
    return Obx(
      () {
        final cs = context.theme.colorScheme;
        final tt = context.theme.textTheme;
        return Scaffold(
          backgroundColor: SettingsSvc.settings.windowEffect.value != WindowEffect.disabled
              ? Colors.transparent
              : cs.surface,
          extendBodyBehindAppBar: true,
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.forum_outlined,
                        size: 30,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      "Keep every chat going",
                      style: tt.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Select a conversation from the list or start a new one.",
                      style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () {
                        NavigationSvc.pushAndRemoveUntil(
                          context,
                          const NewChatCreator(),
                          (route) => route.isFirst,
                        );
                      },
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text("Start chat"),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      "Shortcut: Ctrl+K or Cmd+K",
                      style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
