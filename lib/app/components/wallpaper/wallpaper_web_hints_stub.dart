import 'package:flutter/foundation.dart';

bool get isWebDocumentHidden => false;

bool get webPrefersReducedMotion => false;

int? get webHardwareConcurrency => null;

VoidCallback listenWebVisibilityChange(void Function(bool hidden) onChanged) => () {};
