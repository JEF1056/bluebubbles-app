import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/web/web_interop.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

const String kGoogleMeetWebCallingUrl = 'https://duo.google.com/';

final RegExp _nonDialableMeetChars = RegExp(r'[^0-9*#+]');
final RegExp _hasDigitRegex = RegExp(r'\d');

bool isDialablePhone(String? value) {
  if (value == null) return false;
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.contains('@')) return false;
  return _hasDigitRegex.hasMatch(trimmed);
}

String normalizePhoneForMeet(String value) {
  final trimmed = value.trim();
  final hasLeadingPlus = trimmed.startsWith('+');
  final stripped = trimmed.replaceAll(_nonDialableMeetChars, '').replaceAll('+', '');
  return hasLeadingPlus ? '+$stripped' : stripped;
}

/// Returns unique dialable phone numbers for [handle]/[contact], never emails.
List<String> dialablePhonesForHandle(Handle handle, {ContactV2? contact}) {
  final resolvedContact = contact ?? handle.contactsV2.firstOrNull;
  if (resolvedContact != null) {
    final phones = getUniqueNumbers(
      resolvedContact.phoneNumbers.map((p) => p.number).where(isDialablePhone),
    );
    if (phones.isNotEmpty) return phones;
  }
  if (isDialablePhone(handle.address)) {
    return [handle.address.trim()];
  }
  return const [];
}

Uri buildAndroidWebMeetIntentUri(String normalizedNumber) {
  return Uri.parse(
    'intent://${Uri.encodeComponent(normalizedNumber)}#Intent;'
    'scheme=tel;'
    'package=com.google.android.apps.tachyon;'
    'action=com.google.android.apps.tachyon.action.CALL;'
    'B.com.google.android.apps.tachyon.extra.IS_AUDIO_ONLY=false;'
    'S.browser_fallback_url=https%3A%2F%2Fduo.google.com%2F;'
    'end',
  );
}

Future<void> launchIntent(
  bool video,
  String address, {
  bool isWeb = kIsWeb,
  bool? isAndroidWebOverride,
  Future<bool> Function(Uri url)? launchUrlFn,
  Future<bool> Function(String number)? googleDuoFn,
  Future<void> Function(String text)? copyClipboardFn,
  void Function(String title, String message, {SnackbarType type})? showSnackbarFn,
}) async {
  final launcher = launchUrlFn ??
      (Uri url) => launchUrl(
            url,
            mode: LaunchMode.externalApplication,
            webOnlyWindowName: isWeb ? '_blank' : null,
          );
  final notify = showSnackbarFn ??
      (String title, String message, {SnackbarType type = SnackbarType.info}) =>
          showSnackbar(title, message, type: type);

  if (video) {
    if (!isDialablePhone(address)) return;
    final normalized = normalizePhoneForMeet(address);
    if (isWeb) {
      if (isAndroidWebOverride ?? isAndroidWeb) {
        await launcher(buildAndroidWebMeetIntentUri(normalized));
      } else {
        // Desktop browsers have no URL parameter to auto-ring a number in Google Meet Calling.
        final copy = copyClipboardFn ?? (String text) => Clipboard.setData(ClipboardData(text: text));
        try {
          await copy(normalized);
        } catch (_) {}
        await launcher(Uri.parse(kGoogleMeetWebCallingUrl));
        notify("Google Meet", "Copied $normalized — paste in Google Meet to ring");
      }
      return;
    }

    try {
      final launched = await (googleDuoFn ?? (String n) => MethodChannelSvc.actions.googleDuo(number: n))(normalized);
      if (!launched) {
        notify("Google Meet", "Install Google Meet to place video calls", type: SnackbarType.error);
      }
    } catch (_) {
      notify("Google Meet", "Install Google Meet to place video calls", type: SnackbarType.error);
    }
    return;
  }

  if (address.contains("@")) {
    await launcher(Uri(scheme: "mailto", path: address));
  } else if (isWeb) {
    await launcher(Uri(scheme: "tel", path: address));
  } else if (await Permission.phone.request().isGranted) {
    await launcher(Uri(scheme: "tel", path: address));
  }
}

void showAddressPicker(ContactV2? contact, Handle handle, BuildContext context,
    {bool isEmail = false, bool video = false, bool isLongPressed = false}) async {
  if (video && !isEmail) {
    final items = dialablePhonesForHandle(handle, contact: contact);
    if (items.isEmpty) return;
    if (items.length == 1) {
      launchIntent(true, items.first);
      return;
    }
    if (handle.defaultPhone != null && isDialablePhone(handle.defaultPhone) && !isLongPressed) {
      launchIntent(true, handle.defaultPhone!);
      return;
    }
    _showSelectionDialog(context, handle, items, isEmail: false, video: true);
    return;
  }

  if (contact == null) {
    launchIntent(video, handle.address);
  } else {
    List<String> items = isEmail
        ? getUniqueEmails(contact.emailAddresses.map((e) => e.address))
        : getUniqueNumbers(contact.phoneNumbers.map((p) => p.number));
    if (items.length == 1) {
      launchIntent(video, items.first);
    } else if (!isEmail && handle.defaultPhone != null && !isLongPressed) {
      launchIntent(video, handle.defaultPhone!);
    } else if (isEmail && handle.defaultEmail != null && !isLongPressed) {
      launchIntent(video, handle.defaultEmail!);
    } else {
      _showSelectionDialog(context, handle, items, isEmail: isEmail, video: video);
    }
  }
}

void _showSelectionDialog(
  BuildContext context,
  Handle handle,
  List<String> items, {
  required bool isEmail,
  required bool video,
}) {
  showBBDialog(
    context: context,
    title: "Select Address",
    content: ObxValue<Rx<bool>>(
      (data) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < items.length; i++)
            TextButton(
              child: Text(
                items[i],
                style: context.theme.textTheme.bodyLarge,
                textAlign: TextAlign.start,
              ),
              onPressed: () {
                if (data.value) {
                  if (isEmail) {
                    handle.defaultEmail = items[i];
                    handle.updateDefaultEmail(items[i]);
                  } else {
                    handle.defaultPhone = items[i];
                    handle.updateDefaultPhone(items[i]);
                  }
                }
                launchIntent(video, items[i]);
                Navigator.of(context, rootNavigator: true).pop();
              },
            ),
          Row(
            children: <Widget>[
              SizedBox(
                height: 48.0,
                width: 24.0,
                child: Checkbox(
                  value: data.value,
                  activeColor: context.theme.colorScheme.primary,
                  onChanged: (bool? value) {
                    data.value = value!;
                  },
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent, padding: const EdgeInsets.only(left: 5), elevation: 0.0),
                onPressed: () {
                  data = data.toggle();
                },
                child: Text(
                  "Remember my selection",
                  style: context.theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          Text(
            "Long press the ${isEmail ? "email" : "call"} button to reset your default selection",
            style: context.theme.textTheme.bodySmall!.copyWith(color: context.theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      false.obs,
    ),
  );
}
