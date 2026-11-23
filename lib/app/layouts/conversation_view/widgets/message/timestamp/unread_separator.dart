import 'package:flutter/material.dart';

class UnreadSeparator extends StatelessWidget {
  const UnreadSeparator({
    super.key,
    this.hasTimestampBelow = false,
  });

  final bool hasTimestampBelow;

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: EdgeInsets.only(
        top: 16.0,
        bottom: hasTimestampBelow ? 8.0 : 16.0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              height: 1.0,
              color: primaryColor,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2.0),
            child: Text(
              "Unread",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: primaryColor,
                fontSize: 12.0,
                height: 16.0 / 12.0,
                letterSpacing: 0.4,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1.0,
              color: primaryColor,
            ),
          ),
        ],
      ),
    );
  }
}
