import 'dart:async';
import 'package:universal_io/io.dart';

import 'package:bluebubbles/database/global/platform_file.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// Manages drag-and-drop file operations on the message list.
///
/// Responsibilities:
/// - Track drag state (files over the drop zone)
/// - Validate dropped files
/// - Convert dropped files to PlatformFile objects
/// - Add files to the attachment picker
class DropZoneManager {
  final ConversationViewController controller;

  final RxBool dragging = false.obs;

  final RxInt numFiles = 0.obs;

  DropZoneManager({required this.controller});

  void onDropOver(DropEventDetails event) {
    dragging.value = true;
  }

  void onDropLeave(DropEventDetails event) {
    dragging.value = false;
    numFiles.value = 0;
  }

  Future<void> onPerformDrop(
    DropDoneDetails event,
    ConversationViewController controller,
  ) async {
    numFiles.value = event.files.length;
    try {
      for (final DropItem item in event.files) {
        String fileName = item.name;
        if (fileName.isEmpty) {
          fileName = "Dragged_File_${controller.pickedAttachments.length + 1}";
        }

        if (kIsWeb) {
          if (item is DropItemDirectory) continue;
          try {
            final bytes = await item.readAsBytes();
            if (bytes.isEmpty) continue;
            controller.pickedAttachments.add(PlatformFile(
              name: fileName,
              size: bytes.length,
              bytes: bytes,
            ));
          } catch (_) {
            // Skip unreadable dropped items (e.g. directories reported as DropItem).
          }
          continue;
        }

        if (await FileSystemEntity.type(item.path) != FileSystemEntityType.file) continue;

        controller.pickedAttachments.add(PlatformFile(
          name: fileName,
          path: item.path,
          size: await item.length(),
          bytes: null,
        ));
      }
    } finally {
      dragging.value = false;
      numFiles.value = 0;
    }
  }
}
