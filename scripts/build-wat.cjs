#!/usr/bin/env node
// scripts/build-wat.cjs
// Compiles src/wat/atlas-chart.wat -> public/atlas-chart.wasm using wabt

const fs = require("fs");
const path = require("path");

async function main() {
  const wabt = await require("wabt")();

  const watPath = path.resolve(__dirname, "../src/wat/atlas-chart.wat");
  const wasmPath = path.resolve(__dirname, "../public/atlas-chart.wasm");

  if (!fs.existsSync(watPath)) {
    console.error(`WAT file not found: ${watPath}`);
    process.exit(1);
  }

  const watSource = fs.readFileSync(watPath, "utf8");
  console.log(`Compiling ${watPath}...`);

  try {
    const module = wabt.parseWat(watPath, watSource, {
      mutable_globals: true,
      sat_float_to_int: true,
      sign_extension: true,
      bulk_memory: true,
    });

    const { buffer } = module.toBinary({
      log: false,
      write_debug_names: true,
    });

    fs.mkdirSync(path.dirname(wasmPath), { recursive: true });
    fs.writeFileSync(wasmPath, buffer);
    console.log(`Written ${buffer.byteLength} bytes to ${wasmPath}`);
  } catch (err) {
    console.error("WAT compilation failed:", err.message || err);
    process.exit(1);
  }
}

main();
