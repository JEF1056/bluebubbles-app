import 'package:bluebubbles/helpers/helpers.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

Map<String, int> defaultTimeframes = {"1 Hour": 1, "1 Day": 24, "1 Week": 168, "1 Month": 720};

Future<DateTime?> showTimeframePicker(String title, BuildContext context,
    {bool showHourPicker = true,
    bool presetsAhead = false,
    Map<String, int>? customTimeframes,
    Map<String, int>? additionalTimeframes,
    String? selectionSuffix,
    bool useTodayYesterday = false}) async {
  // Sort the selections by the value without mutating defaultTimeframes
  Map<String, int> tfSelections = Map<String, int>.from(customTimeframes ?? defaultTimeframes);
  tfSelections.addAll(additionalTimeframes ?? {});
  tfSelections = Map.fromEntries(tfSelections.entries.toList()..sort((e1, e2) => e1.value.compareTo(e2.value)));

  final ScrollController controller = ScrollController();
  final scheme = context.theme.colorScheme;
  final hairline = scheme.outlineVariant.withValues(alpha: 0.45);

  Widget buildRow({
    required IconData icon,
    required String label,
    String? trailingText,
    VoidCallback? onTap,
    bool showChevron = false,
  }) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 20, color: scheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: context.theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                if (trailingText != null) ...[
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      trailingText,
                      style: context.theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
                if (showChevron) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right_rounded, size: 24, color: scheme.onSurfaceVariant),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Create a list of row widgets where the left side is the relative timeframe
  // and the right side is the formatted date/time.
  List<Widget> selections = tfSelections.entries.map((entry) {
    final tmpDate = presetsAhead
        ? DateTime.now().toLocal().add(Duration(hours: entry.value))
        : DateTime.now().toLocal().subtract(Duration(hours: entry.value));

    IconData icon = Icons.calendar_today_rounded;
    if (entry.value >= 1 && entry.value < 24) {
      if (tmpDate.hour >= 6 && tmpDate.hour < 12) {
        icon = Icons.wb_sunny_rounded;
      } else if (tmpDate.hour >= 12 && tmpDate.hour < 17) {
        icon = Icons.wb_cloudy_rounded;
      } else if (tmpDate.hour >= 17 && tmpDate.hour < 20) {
        icon = Icons.brightness_3_rounded;
      } else {
        icon = Icons.nights_stay_rounded;
      }
    } else if (entry.value == 24) {
      icon = Icons.calendar_today_rounded;
    } else if (entry.value == 168) {
      icon = Icons.calendar_view_week_rounded;
    } else if (entry.value == 720) {
      icon = Icons.calendar_view_month_rounded;
    }

    final dateStr = tmpDate.isToday()
        ? buildTime(tmpDate)
        : buildFullDate(tmpDate, includeTime: tmpDate.isToday(), useTodayYesterday: useTodayYesterday);

    return buildRow(
      icon: icon,
      label: "${entry.key}${selectionSuffix != null ? " $selectionSuffix" : ""}",
      trailingText: dateStr,
      onTap: () => Navigator.of(context, rootNavigator: true).pop(tmpDate),
    );
  }).toList();

  // Add a custom date picker to the selections list
  selections.add(
    buildRow(
      icon: Icons.edit_calendar_rounded,
      label: "Custom Date",
      showChevron: true,
      onTap: () async {
        final now = DateTime.now();
        DateTime? finalDate;
        if (showHourPicker) {
          finalDate = await showBBDateTimePicker(
            context: context,
            initialDate: now.toLocal(),
            firstDate: now.toLocal().subtract(const Duration(days: 365)),
            lastDate: now.toLocal().add(const Duration(days: 365)),
          );
          if (finalDate != null && !presetsAhead && now.isBefore(finalDate)) {
            showSnackbar("Invalid Date Selection", "Please select a date in the future", type: SnackbarType.error);
            finalDate = null;
          } else if (finalDate != null && presetsAhead && now.isAfter(finalDate)) {
            showSnackbar("Invalid Date Selection", "Please select a date in the past", type: SnackbarType.error);
            finalDate = null;
          }
        } else {
          finalDate = await showDatePicker(
            context: context,
            initialDate: now.toLocal(),
            firstDate: now.toLocal().subtract(const Duration(days: 365)),
            lastDate: now.toLocal().add(const Duration(days: 365)),
            initialEntryMode: kIsDesktop ? DatePickerEntryMode.input : DatePickerEntryMode.calendar,
          );
        }

        if (finalDate != null && context.mounted) {
          Navigator.of(context, rootNavigator: true).pop(finalDate);
        }
      },
    ),
  );

  try {
    return await showBBDialog<DateTime>(
      context: context,
      title: title,
      icon: Icons.schedule_rounded,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Scrollbar(
          thumbVisibility: true,
          controller: controller,
          radius: const Radius.circular(10),
          child: SingleChildScrollView(
            controller: controller,
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: hairline),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < selections.length; i++) ...[
                    if (i > 0) Divider(height: 1, thickness: 1, color: hairline),
                    selections[i],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        BBDialogAction(
          text: "Cancel",
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  } finally {
    controller.dispose();
  }
}
