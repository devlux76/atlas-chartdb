// Atlas ChartDB – WASM loader
// Fetches, compiles and instantiates atlas-chart.wasm

import type { AtlasWasmExports } from "./types.js";

let _cachedModule: WebAssembly.Module | null = null;

/**
 * Load and instantiate the atlas-chart.wasm module.
 * The .wasm file must be served from /atlas-chart.wasm (put in public/).
 */
export async function loadWasm(wasmUrl = "/atlas-chart.wasm"): Promise<AtlasWasmExports> {
  if (!_cachedModule) {
    const response = await fetch(wasmUrl);
    if (!response.ok) {
      throw new Error(`Failed to fetch WASM: ${response.status} ${response.statusText}`);
    }
    const bytes = await response.arrayBuffer();
    _cachedModule = await WebAssembly.compile(bytes);
  }

  const instance = await WebAssembly.instantiate(_cachedModule);
  return instance.exports as unknown as AtlasWasmExports;
}
