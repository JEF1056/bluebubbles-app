import 'dart:async';
import 'dart:math';

import 'package:bluebubbles/app/layouts/settings/pages/server/backup_restore_panel.dart';
import 'package:bluebubbles/app/layouts/settings/settings_page.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/setup/dialogs/failed_to_scan_dialog.dart';
import 'package:bluebubbles/app/layouts/setup/pages/page_template.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shimmer/shimmer.dart';
import 'package:simple_animations/simple_animations.dart';
import 'package:bluebubbles/services/backend/sync/sync_manager_impl.dart' show SyncLogEntry;

class SyncProgress extends StatefulWidget {
  const SyncProgress({super.key});

  @override
  State<SyncProgress> createState() => _SyncProgressState();
}

class _SyncProgressState extends State<SyncProgress> {
  final confettiController = ConfettiController(duration: const Duration(milliseconds: 500));
  final Control animationController = Control.mirror;
  final controller = Get.find<SetupViewController>();
  final Tween<double> tween = Tween<double>(begin: 0, end: 5);
  bool hasPlayed = false;
  Worker? _statusWorker;

  FullSyncManager get syncManager => SyncSvc.fullSyncManager!;

  @override
  void initState() {
    super.initState();

    // Guard against landing on SyncProgress before fullSyncManager is created (e.g. web skips SyncSettings).
    if (SyncSvc.fullSyncManager == null) {
      if (kIsWeb) {
        unawaited(setup.startSetup(25, true, false, false, null));
      } else {
        SyncSvc.initFullSync();
      }
    }

    _statusWorker = ever<SyncStatus>(syncManager.status, (event) async {
      if (!mounted) return;
      String err = syncManager.error ?? "Unknown Error";
      if (event == SyncStatus.COMPLETED_ERROR) {
        await FailedToScanDialog.show(
          context,
          exception: err,
          title: "An error occured during setup!",
        );
        if (!mounted) return;
        controller.pageController.animateToPage(
          controller.pageOfNoReturn - 1,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
      } else if (event == SyncStatus.COMPLETED_SUCCESS && !hasPlayed) {
        setState(() {
          hasPlayed = true;
        });
        confettiController.play();
      }
    });

    if (syncManager.status.value == SyncStatus.COMPLETED_SUCCESS && !hasPlayed) {
      hasPlayed = true;
      confettiController.play();
    }
  }

  @override
  void dispose() {
    _statusWorker?.dispose();
    confettiController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        SetupPageTemplate(
          title: hasPlayed ? "Sync complete!" : "Syncing...",
          subtitle: "",
          customMiddle: hasPlayed
              ? null
              : Column(
                  children: [
                    Obx(() => Text(
                          "${(syncManager.progress.value * 100).toInt()}%",
                          style: context.theme.textTheme.bodyLarge!
                              .apply(
                                fontSizeDelta: 1.5,
                                color: context.theme.colorScheme.onSurface,
                              )
                              .copyWith(height: 2),
                        )),
                    const SizedBox(height: 15),
                    Obx(() => Padding(
                          padding: EdgeInsets.symmetric(horizontal: NavigationSvc.width(context) / 4),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: LinearProgressIndicator(
                              value: syncManager.progress.value == 0 ? null : syncManager.progress.value,
                              backgroundColor: context.theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
                              valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
                            ),
                          ),
                        )),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: NavigationSvc.width(context) * 4 / 5,
                      height: context.height * 1 / 3,
                      child: Container(
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(25),
                            color: context.theme.colorScheme.surfaceContainerHighest),
                        padding: const EdgeInsets.all(10),
                        child: Obx(() => ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                              itemBuilder: (context, index) {
                                SyncLogEntry log = syncManager.output.reversed.toList()[index];
                                return Text(
                                  log.message,
                                  style: TextStyle(
                                    color: log.level == LogLevel.INFO
                                        ? context.theme.colorScheme.onSurfaceVariant
                                        : context.theme.colorScheme.error,
                                    fontSize: 10,
                                  ),
                                );
                              },
                              itemCount: syncManager.output.length,
                            )),
                      ),
                    ),
                  ],
                ),
          customButton: !hasPlayed
              ? const SizedBox.shrink()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(25),
                        gradient: LinearGradient(
                          begin: AlignmentDirectional.topStart,
                          colors: [context.theme.colorScheme.primary, context.theme.colorScheme.primary.darkenPercent(5)],
                        ),
                      ),
                      height: 48,
                      padding: const EdgeInsets.all(2),
                      child: ElevatedButton(
                        style: ButtonStyle(
                          shape: WidgetStateProperty.all<RoundedRectangleBorder>(
                            RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20.0),
                            ),
                          ),
                          backgroundColor: WidgetStateProperty.all(context.theme.colorScheme.surface),
                          shadowColor: WidgetStateProperty.all(context.theme.colorScheme.surface),
                          maximumSize: WidgetStateProperty.all(Size(context.width * 2 / 3, 44)),
                          minimumSize: WidgetStateProperty.all(Size(context.width * 2 / 3, 44)),
                        ),
                        onPressed: () async {
                          Get.offAll(
                              () => ConversationList(
                                    showArchivedChats: false,
                                    showUnknownSenders: false,
                                  ),
                              routeName: "",
                              duration: Duration.zero,
                              transition: Transition.noTransition);
                          Get.delete<SetupViewController>(force: true);
                          Navigator.of(Get.context!).push(
                            ThemeSwitcher.buildPageRoute(
                              builder: (BuildContext context) {
                                return const SettingsPage(
                                  initialPage: BackupRestorePanel(),
                                );
                              },
                            ),
                          );
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.upload, color: context.theme.colorScheme.onSurface, size: 20),
                            const SizedBox(width: 10),
                            Text("Restore Backups",
                                style: context.theme.textTheme.bodyLarge!
                                    .apply(fontSizeFactor: 1.1, color: context.theme.colorScheme.onSurface)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(25),
                        gradient: LinearGradient(
                          begin: AlignmentDirectional.topStart,
                          colors: [context.theme.colorScheme.primary, context.theme.colorScheme.primary.darkenPercent(5)],
                        ),
                      ),
                      height: 48,
                      child: ElevatedButton(
                        style: ButtonStyle(
                          shape: WidgetStateProperty.all<RoundedRectangleBorder>(
                            RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20.0),
                            ),
                          ),
                          backgroundColor: WidgetStateProperty.all(Colors.transparent),
                          shadowColor: WidgetStateProperty.all(Colors.transparent),
                          maximumSize: WidgetStateProperty.all(Size(context.width * 2 / 3, 44)),
                          minimumSize: WidgetStateProperty.all(Size(context.width * 2 / 3, 44)),
                        ),
                        onPressed: () {
                          Get.offAll(
                              () => ConversationList(
                                    showArchivedChats: false,
                                    showUnknownSenders: false,
                                  ),
                              routeName: "",
                              duration: Duration.zero,
                              transition: Transition.noTransition);
                          Get.delete<SetupViewController>(force: true);
                        },
                        child: Shimmer.fromColors(
                          baseColor: context.theme.colorScheme.onPrimary.withValues(alpha: 0.7),
                          highlightColor: context.theme.colorScheme.onPrimary,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CustomAnimationBuilder<double>(
                                control: animationController,
                                tween: tween,
                                duration: const Duration(milliseconds: 600),
                                curve: Curves.easeOut,
                                builder: (context, _, anim) {
                                  return Padding(
                                    padding: const EdgeInsets.only(left: 0.0),
                                    child: Icon(Icons.check, color: context.theme.colorScheme.onPrimary, size: 25),
                                  );
                                },
                              ),
                              Padding(
                                padding: const EdgeInsets.only(right: 0.0, left: 5.0),
                                child: Text("Finish",
                                    style: context.theme.textTheme.bodyLarge!
                                        .apply(fontSizeFactor: 1.1, color: context.theme.colorScheme.onPrimary)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        ConfettiWidget(
          confettiController: confettiController,
          blastDirection: pi / 2,
          blastDirectionality: BlastDirectionality.explosive,
          emissionFrequency: 0.35,
        ),
      ],
    );
  }
}
