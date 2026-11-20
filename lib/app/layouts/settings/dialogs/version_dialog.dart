import 'dart:math';

import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

void showVersionDialog(BuildContext context) {
  final packageInfoFuture = PackageInfo.fromPlatform();
  showBBDialog<void>(
    context: context,
    title: "BlueBubbles",
    content: FutureBuilder<PackageInfo>(
      future: packageInfoFuture,
      builder: (BuildContext ctx, AsyncSnapshot<PackageInfo> snapshot) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                "assets/icon/icon.png",
                width: 40,
                height: 40,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (!kIsDesktop)
                    Text(
                      "Version Number: ${snapshot.hasData ? snapshot.data!.version : "N/A"}",
                      style: Theme.of(ctx).textTheme.bodyMedium,
                    ),
                  if (!kIsDesktop)
                    Text(
                      "Version Code: ${snapshot.hasData ? snapshot.data!.buildNumber.lastChars(min(4, snapshot.data!.buildNumber.length)) : "N/A"}",
                      style: Theme.of(ctx)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                    ),
                  if (kIsDesktop)
                    Text(
                      appVersion,
                      style: Theme.of(ctx).textTheme.bodyMedium,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    ),
    actions: <BBDialogAction>[
      BBDialogAction(
        text: "View Licenses",
        onPressed: () async {
          final info = await packageInfoFuture;
          if (!context.mounted) return;
          Navigator.of(context, rootNavigator: true).pop();
          NavigationSvc.push(
            context,
            Builder(
              builder: (context) => Theme(
                data: Theme.of(context).copyWith(
                  scaffoldBackgroundColor: context.headerColor,
                  appBarTheme: Theme.of(context)
                      .appBarTheme
                      .copyWith(backgroundColor: context.headerColor, toolbarHeight: kIsDesktop ? 80 : null),
                  cardColor: context.tileColor,
                ),
                child: LicensePage(
                  applicationName: "BlueBubbles",
                  applicationVersion: info.version,
                  applicationIcon: Image.asset(
                    "assets/icon/icon.png",
                    width: 30,
                    height: 30,
                  ),
                ),
              ),
            ),
          );
        },
      ),
      BBDialogAction(
        text: "Close",
        isDefault: true,
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    ],
  );
}
