{{flutter_js}}
{{flutter_build_config}}

// Versioned asset prefix bypasses stale Cloudflare edge-cached /assets/* entries on deploy.
const _bbWasmHash = (_flutter.buildConfig?.wasmHashes?.['main.dart.wasm'] || '').slice(0, 10);
const _bbIsLocal = location.hostname === 'localhost' || location.hostname === '127.0.0.1';
const _bbAssetBase = _bbIsLocal ? undefined : `${location.origin}/_a/v5-${_bbWasmHash || 'web'}/`;

_flutter.loader.load({
  config: _bbAssetBase ? { assetBase: _bbAssetBase } : undefined,
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine({
      useColorEmoji: true,
      ...(_bbAssetBase ? { assetBase: _bbAssetBase } : {}),
    });
    await appRunner.runApp();
  },
});
