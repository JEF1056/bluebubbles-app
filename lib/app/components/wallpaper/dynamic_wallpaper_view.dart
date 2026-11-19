import 'package:bluebubbles/app/components/wallpaper/dynamic_wallpaper_definition.dart';
import 'package:bluebubbles/app/components/wallpaper/wallpaper_web_hints.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Resolves a `dynamicWallpaperId` + config map to the actual animated
/// wallpaper widget via [DynamicWallpaperRegistry]. Used both as the live
/// chat background (`GradientBackground`) and as the small-scale preview on
/// the picker gallery tiles / config screen — callers control interactivity
/// and clipping, this just renders.
///
/// Pauses descendant tickers via [TickerMode] when the browser tab is hidden
/// (`document.hidden`) or when reduced motion is requested.
class DynamicWallpaperView extends StatefulWidget {
  final String? wallpaperId;
  final Map<String, dynamic>? config;

  const DynamicWallpaperView({super.key, required this.wallpaperId, required this.config});

  @override
  State<DynamicWallpaperView> createState() => _DynamicWallpaperViewState();
}

class _DynamicWallpaperViewState extends State<DynamicWallpaperView> {
  bool _webHidden = isWebDocumentHidden;
  VoidCallback? _disposeVisibilityListener;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _disposeVisibilityListener = listenWebVisibilityChange((hidden) {
        if (mounted && _webHidden != hidden) {
          setState(() => _webHidden = hidden);
        }
      });
    }
  }

  @override
  void dispose() {
    _disposeVisibilityListener?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final definition = DynamicWallpaperRegistry.byId(widget.wallpaperId);
    if (definition == null) return const SizedBox.shrink();
    final resolvedConfig = widget.config ?? definition.defaultConfig(context, isIMessage: true);
    final reducedMotion = MediaQuery.disableAnimationsOf(context) || (kIsWeb && webPrefersReducedMotion);
    final tickersEnabled = !reducedMotion && !(kIsWeb && _webHidden);
    return TickerMode(
      enabled: tickersEnabled,
      child: IgnorePointer(child: definition.buildView(context, resolvedConfig)),
    );
  }
}
