# ⚡ Atlas ChartDB

> A reusable WebAssembly-powered charting component for browser apps. Atlas ChartDB renders directly to a canvas from a single `.wat` / `.wasm` engine, with TypeScript glue for loading data, managing datasets, and handling interaction.

Atlas ChartDB is designed for reuse in frontend applications, live demos, dashboards, and embed scenarios where low-level pixel rendering, compact binary dataset persistence, and smooth interaction are required.

---

## What is Atlas ChartDB?

Atlas ChartDB is a lightweight charting component with the following goals:

- Native canvas rendering through a single WebAssembly module.
- Compact binary dataset storage for fast load/save and client-side persistence.
- Supported OHLCV and time-value dataset models.
- Built-in indicators, crosshair, pan/zoom, and touch support.
- Vanilla TypeScript interface for embedding in any modern bundler or browser app.

This package is the reusable component layer. It exposes a public API for:

- `AtlasChart` — the main chart bridge class.
- `packRGBA()` — helper for converting colors.
- enums for chart, dataset, and indicator types.
- OPFS dataset persistence utilities.
- WASM loader helper.

---

## Package structure

```
atlas-chartdb/
  package.json
  README.md
  public/
    atlas-chart.wasm
  src/ts/
    chart.ts
    data-store.ts
    index.ts
    types.ts
    wasm-loader.ts
```

Key responsibilities:

- `chart.ts`: The `AtlasChart` bridge, event handling, render loop, dataset loading, indicators, and interaction.
- `wasm-loader.ts`: Fetches and instantiates the WASM module.
- `data-store.ts`: OPFS persistence for `.bin` datasets.
- `types.ts`: Public type definitions for records, enums, and the WASM export interface.

---

## Browser compatibility

Atlas ChartDB targets modern browsers with the following capabilities:

- WebAssembly support.
- Canvas 2D rendering.
- Origin Private File System (OPFS) for dataset persistence.

`OPFS` is currently available in Chromium-based browsers. If you need to support older browsers, replace or extend `data-store.ts` with an alternate storage implementation.

---

## Public API overview

### Main exports

```ts
import {
  AtlasChart,
  packRGBA,
  DatasetType,
  ChartType,
  IndicatorType,
  loadWasm,
  writeDatasetBin,
  readDatasetBin,
  listDatasets,
  deleteDataset,
} from "./src/ts/index.js";
```

### Primary classes and helpers

- `AtlasChart(canvas: HTMLCanvasElement, wasmUrl = "/atlas-chart.wasm")`
- `AtlasChart.init(): Promise<void>`
- `AtlasChart.destroy(): void`
- `packRGBA(r, g, b, a?)`
- `loadWasm(wasmUrl): Promise<AtlasWasmExports>`

### Enums

- `ChartType`: `Candlestick`, `Line`, `Area`, `OhlcBar`, `Volume`, `Scatter`
- `DatasetType`: `OHLCV`, `TimeValue`
- `IndicatorType`: `SMA`, `EMA`, `BB`, `RSI`, `MACD`

---

## Quick integration guide

### 1. Add a canvas to your page

```html
<canvas id="atlas-chart" width="1200" height="650"></canvas>
```

### 2. Create the chart instance

```ts
import { AtlasChart, ChartType, IndicatorType, packRGBA } from "./src/ts/index.js";

const canvas = document.querySelector<HTMLCanvasElement>("#atlas-chart")!;
const chart = new AtlasChart(canvas);
await chart.init();

chart.setChartType(ChartType.Candlestick);
chart.setShowVolume(true, 110);
chart.setMargins(50, 10, 20, 40);
```

### 3. Load OHLCV data

```ts
const dsId = chart.loadOhlcv([
  { timestamp: 1700000000000, open: 100, high: 110, low: 98, close: 105, volume: 1200 },
  // ... more records in ascending timestamp order
]);
chart.setActiveDataset(dsId);
chart.fitToData(dsId);
```

### 4. Add indicators

```ts
chart.addIndicator({
  type: IndicatorType.SMA,
  dsId,
  period: 20,
  color: packRGBA(255, 220, 50),
});

chart.addIndicator({
  type: IndicatorType.BB,
  dsId,
  period: 20,
  color: packRGBA(130, 100, 220),
  param1: 2.0,
});
```

### 5. Persist datasets to OPFS

```ts
await chart.saveToOpfs(dsId, "btc-daily");
const loadedId = await chart.loadFromOpfs("btc-daily");
```

---

## AtlasChart API reference

> `AtlasChart` is the main reusable component class. It wraps a canvas and delegates rendering to the WASM engine.

### Lifecycle

- `constructor(canvas: HTMLCanvasElement, wasmUrl = "/atlas-chart.wasm")`
- `async init()` — loads WASM, initializes the engine, and attaches event listeners.
- `destroy()` — tears down event listeners and cancels render animation frames.
- `get ready(): boolean`

### Canvas and layout

- `resize(width, height)` — resize the canvas and reinitialize the WASM viewport.
- `setTheme(bg, grid, text, up, down, line)` — customise chart colors.
- `setMargins(left, top, right, bottom)` — control chart padding.
- `setShowVolume(show, panelH = 80)` — show or hide the volume panel.
- `setIndicatorPanel(show, height = 70)` — show/hide the lower indicator panel.

### Dataset loading and querying

- `loadOhlcv(records: OhlcvRecord[]): number`
- `loadTimeValue(records: TimeValueRecord[]): number`
- `async loadFromOpfs(name: string): Promise<number>`
- `async saveToOpfs(dsId: number, name: string): Promise<void>`
- `setActiveDataset(dsId: number)`
- `fitToData(dsId?: number)`
- `getRecordCount(dsId: number): number`
- `getOhlcvAt(dsId: number, idx: number): OhlcvRecord | null`

### Chart controls

- `setChartType(type: ChartType)`
- `setViewRange(range: { start: number; end: number })`
- `getViewRange(): { start: number; end: number }`
- `autoScalePrice()`
- `setPriceRange(min, max)`
- `getPriceRange(): { min: number; max: number }`
- `render()` — force immediate redraw.

### Indicator management

- `addIndicator(opts: IndicatorOptions): number`
- `removeIndicator(indId: number)`
- `recomputeIndicators()`

### Event handling

`AtlasChart` extends `EventTarget`; subscribe with `addEventListener`.

Supported events:

- `hover` — detail `{ x, y, index, ts, price }`
- `click` — detail `{ x, y, index, ts, price }`
- `zoom` — detail `ViewRange`
- `pan` — detail `ViewRange`
- `resize` — detail `{ width, height }`

Example:

```ts
chart.addEventListener("hover", (event) => {
  const detail = (event as CustomEvent).detail;
  console.log("hover", detail.index, detail.ts, detail.price);
});
```

---

## Data models and types

### OHLCV record

```ts
interface OhlcvRecord {
  timestamp: number;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
}
```

### TimeValue record

```ts
interface TimeValueRecord {
  timestamp: number;
  value: number;
}
```

### Indicator options

```ts
interface IndicatorOptions {
  type: IndicatorType;
  dsId: number;
  period: number;
  color: PackedColor;
  param1?: number; // BB stddev multiplier, MACD fast period
  param2?: number; // MACD slow period
  param3?: number; // MACD signal period
}
```

### Color packing helper

Use `packRGBA(r, g, b, a?)` to convert CSS-style colors into the packed integer expected by the WASM engine.

```ts
const yellow = packRGBA(255, 220, 50);
```

---

## Persistence and binary dataset format

Atlas ChartDB stores dataset files as compact binary `.bin` blobs. This is useful for fast save/load cycles and low-memory persistence.

### OPFS helpers

The package exports:

- `writeDatasetBin(name, data)`
- `readDatasetBin(name)`
- `listDatasets()`
- `deleteDataset(name)`

These functions store files under the OPFS directory `atlas-chartdb`.

### Binary record format

The file header is 72 bytes long and includes:

- `0..4` — magic `ATLC` (`0x434C5441`)
- `4..8` — version `DB10` (`0x30314244`)
- `8..12` — dataset type (`0=OHLCV`, `1=TimeValue`)
- `12..20` — record count (i64)
- `20..28` — timestamp start (ms, i64)
- `28..36` — timestamp end (ms, i64)
- `36..72` — reserved

Payload:

- OHLCV records: `N × 48 bytes`
- TimeValue records: `N × 16 bytes`

Each OHLCV record contains:

- timestamp (i64)
- open (f64)
- high (f64)
- low (f64)
- close (f64)
- volume (f64)

Each TimeValue record contains:

- timestamp (i64)
- value (f64)

---

## Build and development

Install dependencies and run the development server:

```bash
bun install
bun run dev
```

Build the WASM module and bundle TypeScript:

```bash
bun run build:wat
bun run build:ts
bun run build
```

The `.wat` compilation step emits `public/atlas-chart.wasm`. Ensure that your host serves this file at the path passed to `AtlasChart` or `loadWasm()`.

---

## Reuse recommendations

### Embedding inside another app

1. Copy the `atlas-chartdb` folder into your monorepo or install it as a package.
2. Make sure the `.wasm` file is available from the same origin.
3. Import `AtlasChart` and `types` from the package entrypoint.
4. Mount a canvas and call `await chart.init()` before loading data.

### Custom UI and controls

- Use `chart.setChartType()` to switch visualizations.
- Use `chart.setViewRange()` and `chart.fitToData()` to control the visible timeframe.
- Use `chart.addIndicator()` / `chart.removeIndicator()` for overlays and lower panels.
- Subscribe to `hover` and `click` for custom tooltips or telemetry.

### Packaging

- In a production build, include `public/atlas-chart.wasm` in the static assets.
- If your bundler rewrites import paths, keep `wasmUrl` aligned with the final public path.
- The component is intentionally unopinionated about UI frameworks; it works with Vanilla JS, React, Svelte, Vue, and others.

---

## Troubleshooting

- If `AtlasChart.init()` fails, verify the WASM file path and that the server responds with `200`.
- If OPFS fails, check browser support and secure origin requirements (`https://` or localhost).
- If rendering is blank, confirm the canvas has non-zero width/height before `chart.init()`.
- Use `chart.destroy()` when removing the chart from the DOM to avoid stale event listeners.

---

## License

This repo does not include a license declaration in the package metadata. If you reuse this component, adapt the license and attribution to your project policies.

