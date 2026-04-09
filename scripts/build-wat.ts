// scripts/build-wat.ts — compiles src/wat/atlas-chart.wat → public/atlas-chart.wasm
// Run with: bun scripts/build-wat.ts

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// wabt is a CJS default-export factory that returns a Promise
const WabtFactory = (await import("wabt")).default as (opts?: object) => Promise<WabtModule>;
const wabt = await WabtFactory();

const watPath  = resolve(__dirname, "../src/wat/atlas-chart.wat");
const wasmPath = resolve(__dirname, "../public/atlas-chart.wasm");

if (!existsSync(watPath)) {
  console.error(`WAT file not found: ${watPath}`);
  process.exit(1);
}

const watSource = readFileSync(watPath, "utf8");
console.log(`Compiling ${watPath}…`);

try {
  const module = wabt.parseWat(watPath, watSource, {
    mutable_globals:  true,
    sat_float_to_int: true,
    sign_extension:   true,
    bulk_memory:      true,
  });

  const { buffer } = module.toBinary({ log: false, write_debug_names: true });

  mkdirSync(dirname(wasmPath), { recursive: true });
  writeFileSync(wasmPath, new Uint8Array(buffer));
  console.log(`✓  Written ${buffer.byteLength} bytes → ${wasmPath}`);
} catch (err: unknown) {
  console.error("WAT compilation failed:", err instanceof Error ? err.message : String(err));
  process.exit(1);
}

// ── TypeScript shim for the wabt module type ──────────────────────────────────
interface WabtModule {
  parseWat(
    filename: string,
    source: string,
    options?: Record<string, boolean>,
  ): {
    toBinary(opts: { log: boolean; write_debug_names: boolean }): { buffer: Uint8Array };
  };
}
