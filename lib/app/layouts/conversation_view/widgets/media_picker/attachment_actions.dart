import 'dart:async';

import 'package:bluebubbles/app/components/subscription_required.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/timeframe_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/emoji_picker_popover.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/genmoji_dialog.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/genmoji_library_popover.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_library_dialog.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/buttons/text_field_button.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/genmoji.dart';
import 'package:bluebubbles/models/library_sticker.dart';
import 'package:bluebubbles/services/network/api/sticker_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/chat/send_data.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/utils/share.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart' as pf;
import 'package:file_picker/file_picker.dart' hide PlatformFile;
import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:get/get.dart';
import 'package:klipy_flutter/klipy_flutter.dart';
import 'package:hand_signature/signature.dart';
import 'package:universal_io/io.dart';

/// The composer's "add something" actions, shared by the mobile attachment picker
/// (`AttachmentPicker`) and the desktop `+` menu (`showDesktopAttachmentMenu`), so both offer
/// the same features with the same rules.
///
/// Camera and the photo-library grid stay in the mobile picker: they need `image_picker`'s
/// camera and `photo_manager`, which have no desktop implementation.
class AttachmentActions {
  AttachmentActions._();

  static const int _maxFileBytes = 1000 * 1024000;

  static void _tooLarge() =>
      showSnackbar("Error", "This file is over 1 GB! Please compress it before sending.", type: SnackbarType.error);

  /// Prompts for files and adds them to the draft. Desktop reads the bytes now (its picked
  /// paths can be sandbox-scoped and gone by send time); mobile keeps the path and reads at
  /// send, so a large video isn't held in memory while the user types.
  static Future<void> pickFiles(ConversationViewController controller) async {
    final res = await FilePicker.pickFiles();
    for (pf.PlatformFile file in res) {
      final size = await file.length() ?? 0;
      if (size > _maxFileBytes) {
        _tooLarge();
        continue;
      }
      controller.pickedAttachments.add(
        PlatformFile(
          path: file.path,
          name: file.name,
          size: size,
          bytes: (kIsDesktop || kIsWeb) ? await file.readAsBytes() : null,
        ),
      );
    }
  }

  /// [context] anchors anything that pops up, like the Genmoji popover.
  static Future<void> run(TextFieldButton button, BuildContext context, ConversationViewController controller) async =>
      switch (button) {
        TextFieldButton.Files => pickFiles(controller),
        TextFieldButton.Genmoji => showGenmojiLibraryPopover(context, controller),
        TextFieldButton.Stickers => showStickerLibraryPopover(context, controller),
        TextFieldButton.Handwritten => handwritten(context, controller),
        TextFieldButton.Schedule => schedule(context, controller),
        TextFieldButton.Location => shareLocation(controller),
        TextFieldButton.Gif => pickGif(context, controller),
        TextFieldButton.Emoji => showEmojiPickerPopover(context, controller),
      };

  static Future<void> pickGif(BuildContext context, ConversationViewController controller) async {
    if (kIsDesktop || kIsWeb) {
      controller.showingOverlays = true;
    }
    KlipyClient klipy = KlipyClient(apiKey: kIsWeb ? KLIPY_API_KEY : dotenv.get('KLIPY_API_KEY'));
    TextEditingController klipyController = TextEditingController();
    FocusNode focus = FocusNode();
    Future<KlipyResultObject?> resultFuture = klipy.showAsBottomSheet(
      maxExtent: 0.8,
      minExtent: 0.5,
      debounce: const Duration(seconds: 1),
      context: context,
      searchFieldController: klipyController,
      // Copied and slightly modified from source, just so I can autofocus
      searchFieldWidget: Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          focusNode: focus,
          controller: klipyController,
          decoration: InputDecoration(
            prefixIcon: Icon(Icons.search_rounded, color: context.theme.colorScheme.onSurfaceVariant, size: 24),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            filled: true,
            fillColor: context.theme.colorScheme.surfaceContainerHighest,
            hintStyle: context.theme.textTheme.bodyMedium?.copyWith(color: context.theme.colorScheme.onSurfaceVariant),
            hintText: "Search GIFs",
            isDense: true,
          ),
          style: context.theme.textTheme.bodyMedium!,
        ),
      ),
      style: KlipyStyle(
        color: context.theme.colorScheme.surfaceContainerHigh,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        attributionStyle: KlipyAttributionStyle(brightnes: context.theme.brightness),
        tabBarStyle: KlipyTabBarStyle(
          decoration: BoxDecoration(
            color: context.theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          indicator: BoxDecoration(
            color: context.theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(10),
          ),
          labelColor: context.theme.colorScheme.onPrimary,
          unselectedLabelColor: context.theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    focus.requestFocus();
    KlipyResultObject? result = await resultFuture;
    if (kIsDesktop || kIsWeb) {
      controller.showingOverlays = false;
    }
    final selectedGif = result?.media.tinyGif ?? result?.media.tinyGifTransparent;
    if (result != null && selectedGif != null) {
      final response = await HttpSvc.downloadFromUrl(selectedGif.url);
      if (response.statusCode == 200) {
        try {
          final Uint8List data = response.data;
          controller.pickedAttachments.add(PlatformFile(
            path: null,
            name: "${result.id}.gif",
            size: data.length,
            bytes: data,
          ));
        } catch (e, s) {
          Logger.warn("Failed to attach GIF from picker", error: e, trace: s, tag: 'AttachmentActions');
        }
      }
    }
  }

  /// Location sharing needs `geolocator`, which has no Linux implementation.
  static bool get supportsLocation => kIsWeb || !Platform.isLinux;

  static Future<void> shareLocation(ConversationViewController controller) => Share.location(controller.chat);

  static Future<void> schedule(BuildContext context, ConversationViewController controller) async {
    if (controller.pickedAttachments.isNotEmpty) {
      return showSnackbar("Error", "Remove all attachments before scheduling!", type: SnackbarType.error);
    } else if (controller.replyToMessage != null || controller.subjectTextController.text.isNotEmpty) {
      return showSnackbar("Error", "Private API features are not supported when scheduling!", type: SnackbarType.error);
    }

    final date = await showTimeframePicker("Pick date and time", context, presetsAhead: true);
    if (date != null && date.isAfter(DateTime.now())) {
      controller.scheduledDate.value = date;
    }
  }

  /// Picks an ink color, then a square to draw in, and attaches the drawing as a handwritten
  /// message. Works with a mouse or pen as well as touch.
  static Future<void> handwritten(BuildContext context, ConversationViewController controller) async {
    Color selectedColor = context.theme.colorScheme.bubble(context, controller.chat.isIMessage);
    // A conversation pane on desktop can be a thousand pixels wide; the dialogs are sized for
    // a phone, so cap them there rather than stretching the canvas to fill it.
    final availableDialogWidth = MediaQuery.sizeOf(context).width - 32;
    final dialogWidth = (kIsDesktop || kIsWeb)
        ? (availableDialogWidth < 420.0 ? availableDialogWidth : 420.0).clamp(240.0, 420.0)
        : NavigationSvc.width(context) - 70;

    final result =
        await ColorPicker(
          color: selectedColor,
          onColorChanged: (Color newColor) {
            selectedColor = newColor;
          },
          title: Text("Select Color", style: context.theme.textTheme.titleLarge),
          width: 40,
          height: 40,
          spacing: 0,
          runSpacing: 0,
          borderRadius: 0,
          wheelDiameter: 165,
          enableOpacity: false,
          showColorCode: true,
          colorCodeHasColor: true,
          pickersEnabled: <ColorPickerType, bool>{ColorPickerType.wheel: true},
          copyPasteBehavior: const ColorPickerCopyPasteBehavior(parseShortHexCode: true),
          actionButtons: const ColorPickerActionButtons(dialogActionButtons: true),
        ).showPickerDialog(
          context,
          barrierDismissible: false,
          backgroundColor: context.theme.colorScheme.surfaceContainerHigh,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          constraints: BoxConstraints(minHeight: 480, minWidth: dialogWidth, maxWidth: dialogWidth),
        );

    if (!result || !context.mounted) return;
    final control = HandSignatureControl();
    final scheme = context.theme.colorScheme;
    final canvasDimension = (dialogWidth - 40).clamp(200.0, 380.0);
    Widget canvas = Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.55)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          HandSignature(
            control: control,
            color: selectedColor,
            width: 1.0,
            maxWidth: 10.0,
            type: SignatureDrawType.shape,
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton.filledTonal(
              tooltip: "Clear",
              icon: const Icon(Icons.refresh_rounded, size: 24),
              style: IconButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
              ),
              onPressed: control.clear,
            ),
          ),
        ],
      ),
    );
    canvas = (kIsDesktop || kIsWeb) ? SizedBox.square(dimension: canvasDimension, child: canvas) : AspectRatio(aspectRatio: 1, child: canvas);

    await showBBDialog(
      context: context,
      title: "Draw Handwritten Message",
      icon: Icons.draw_rounded,
      content: canvas,
      actions: [
        BBDialogAction(
          text: "Cancel",
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
        BBDialogAction(
          text: "Attach",
          isDefault: true,
          onPressed: () async {
            Navigator.of(context, rootNavigator: true).pop();
            final bytes = await control.toImage(height: 512, fit: false);
                if (bytes != null) {
                  final uint8 = bytes.buffer.asUint8List();
                  controller.pickedAttachments.add(
                    PlatformFile(
                      path: null,
                      name: "handwriten-${controller.pickedAttachments.length + 1}.png",
                      bytes: uint8,
                      size: uint8.lengthInBytes,
                      balloonBundleId: 'com.apple.Handwriting.HandwritingProvider',
                    ),
                  );
                }
              },
            ),
          ],
        );
  }

  // ---------------------------------------------------------------------------
  // Stickers
  // ---------------------------------------------------------------------------

  /// Library stickers whose full-size image is downloading/sending, so their tiles show progress.
  static final RxSet<String> sendingStickers = <String>{}.obs;

  /// Sends [sticker] as a standalone message attachment (or stages it in [controller.pickedAttachments] when no
  /// `sendFunc` is attached).
  static Future<void> sendStandaloneSticker(
    ConversationViewController controller,
    LibrarySticker sticker,
  ) async {
    if (sendingStickers.contains(sticker.identifier)) return;
    sendingStickers.add(sticker.identifier);
    try {
      final bytes = await StickerLibrarySvc.imageForSending(sticker);
      final file = PlatformFile(
        path: null,
        name: "sticker-${sticker.identifier}.${sticker.fileExtension}",
        bytes: bytes,
        size: bytes.lengthInBytes,
      );
      if (controller.sendFunc != null) {
        await controller.send(SendData(attachments: [file], text: '', subject: ''));
      } else {
        controller.pickedAttachments.add(file);
      }
    } catch (e, s) {
      Logger.error("Failed to send standalone sticker", error: e, trace: s, tag: 'StickerLibrary');
      showSnackbar("Error", stickerRefusal(e).message ?? "Couldn't send that sticker.", type: SnackbarType.error);
    } finally {
      sendingStickers.remove(sticker.identifier);
    }
  }

  // ---------------------------------------------------------------------------
  // Genmoji
  // ---------------------------------------------------------------------------

  /// Library Genmoji whose send-size image is downloading, so their tiles show progress.
  static final RxSet<String> attachingGenmoji = <String>{}.obs;

  static String _genmojiFileName(String identifier) => "genmoji-$identifier.png";

  static bool isGenmojiAttached(ConversationViewController controller, GenmojiLibraryEntry entry) =>
      controller.pickedAttachments.any((f) => f.name == _genmojiFileName(entry.identifier));

  /// Adds a library Genmoji to the draft, or takes it back out if it's already there — the
  /// same toggle the photo grid uses.
  static Future<void> toggleLibraryGenmoji(ConversationViewController controller, GenmojiLibraryEntry entry) async {
    final name = _genmojiFileName(entry.identifier);
    if (controller.pickedAttachments.any((f) => f.name == name)) {
      controller.pickedAttachments.removeWhere((f) => f.name == name);
      return;
    }
    await attachLibraryGenmoji(controller, entry);
  }

  /// Adds a library Genmoji to the draft (no-op when it's already attached).
  static Future<void> attachLibraryGenmoji(ConversationViewController controller, GenmojiLibraryEntry entry) async {
    final name = _genmojiFileName(entry.identifier);
    if (controller.pickedAttachments.any((f) => f.name == name) || attachingGenmoji.contains(entry.identifier)) {
      return;
    }
    attachingGenmoji.add(entry.identifier);
    try {
      final png = await GenmojiLibrarySvc.imageForSending(entry);
      controller.pickedAttachments.add(PlatformFile(path: null, name: name, bytes: png, size: png.lengthInBytes));
    } on GenmojiException catch (e) {
      showSnackbar("Error", e.message, type: SnackbarType.error);
    } on DioException catch (e, s) {
      Logger.error("Failed to download Genmoji", error: e, trace: s, tag: 'Genmoji');
      showSnackbar("Error", "Couldn't download that Genmoji from your server.", type: SnackbarType.error);
    } catch (e, s) {
      // e.g. the cache directory isn't writable.
      Logger.error("Failed to attach Genmoji", error: e, trace: s, tag: 'Genmoji');
      showSnackbar("Error", "Couldn't attach that Genmoji.", type: SnackbarType.error);
    } finally {
      attachingGenmoji.remove(entry.identifier);
    }
  }

  /// Opens the Genmoji creator and attaches what the user keeps. Resolves true when something
  /// was attached. The library is re-synced afterwards either way, since the Mac files what
  /// it draws there (macOS 27's Image Playground always does).
  static Future<bool> createGenmoji(BuildContext context, ConversationViewController controller) async {
    if (SubscriptionSvc.locked) {
      await showSubscriptionRequired(
        context,
        feature: ProFeature.genmoji,
        onUnlocked: () => context.mounted ? createGenmoji(context, controller) : null,
      );
      return false;
    }
    final image = await showGenmojiDialog(context, isIMessage: controller.chat.isIMessage);
    unawaited(GenmojiLibrarySvc.sync());
    if (image == null) return false;
    controller.pickedAttachments.add(
      PlatformFile(
        path: null,
        name: "genmoji-${DateTime.now().millisecondsSinceEpoch}.png",
        bytes: image.png,
        size: image.png.lengthInBytes,
      ),
    );
    return true;
  }

  /// Confirms, then deletes a Genmoji from the Mac's library (and so from every device on the
  /// account). Also takes it out of the draft if it was attached.
  static Future<void> deleteGenmoji(
    BuildContext context,
    ConversationViewController controller,
    GenmojiLibraryEntry entry,
  ) async {
    final confirmed = Completer<bool>();
    await showAreYouSure(
      context,
      title: "Delete Genmoji?",
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!kIsWeb && GenmojiLibrarySvc.cachedThumbnails.contains(entry.identifier)) ...[
            Image.file(GenmojiLibrarySvc.thumbnailFile(entry.identifier), width: 88, height: 88),
            const SizedBox(height: 12),
          ],
          Text(
            "${entry.description.isEmpty ? 'This Genmoji' : '"${entry.description}"'} will be removed from your "
            "Mac and every device signed in to its iCloud account.",
            textAlign: TextAlign.center,
          ),
        ],
      ),
      noText: "Cancel",
      yesText: "Delete",
      yesIsDestructive: true,
      yesColor: context.theme.colorScheme.error,
      onNo: () {
        Navigator.of(context, rootNavigator: true).pop();
        confirmed.complete(false);
      },
      onYes: () {
        Navigator.of(context, rootNavigator: true).pop();
        confirmed.complete(true);
      },
    );
    // Dismissed by tapping outside: neither button ran.
    if (!confirmed.isCompleted || !await confirmed.future) return;

    try {
      await GenmojiLibrarySvc.delete(entry);
      controller.pickedAttachments.removeWhere((f) => f.name == _genmojiFileName(entry.identifier));
    } on GenmojiException catch (e) {
      showSnackbar("Couldn't Delete Genmoji", e.message, type: SnackbarType.error);
    } catch (e, s) {
      Logger.error("Failed to delete Genmoji", error: e, trace: s, tag: 'Genmoji');
      showSnackbar("Error", "Couldn't reach your server to delete that Genmoji.", type: SnackbarType.error);
    }
  }
}
