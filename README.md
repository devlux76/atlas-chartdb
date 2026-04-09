# ⚡ Atlas ChartDB

> **WebAssembly-powered financial charting library** — all heavy lifting happens inside a single `.wat` / `.wasm` module that writes pixel-perfect frames directly to a canvas `ImageData` buffer. TypeScript is a thin bridge that marshals data, handles user events and manages OPFS persistence.

![Atlas ChartDB – all chart types](https://github.com/user-attachments/assets/161805ce-4ca9-4c81-84db-b7778e897e4b)

---

## Architecture

```
 TypeScript (thin bridge)          WebAssembly (.wat / .wasm)
 ──────────────────────────        ──────────────────────────────────────
  AtlasChart class                  Memory layout (256 pages = 16 MB)
    │                                 0x000000  config header (256 B)
    ├─ loadOhlcv / loadTimeValue  ──► 0x000100  dataset registry (32 × 256 B)
    ├─ loadFromOpfs / saveToOpfs      0x002100  indicator registry (16 × 256 B)
    ├─ addIndicator                   0x003100  scratch area
    ├─ setChartType / fitToData       0x010000  framebuffer (RGBA, up to 2048×1024)
    ├─ pan / zoom events         ◄──  0x810000  dataset + indicator value storage
    └─ render() → blit to canvas      0x3E00    3×5 pixel font bitmaps
```

**No third-party charting runtime.** Every pixel is written by the WAT module.

---

## Features

### Chart types (all in `.wat`)
| Type | Description |
|------|-------------|
| **Candlestick** | Full OHLC body + wicks, coloured by up/down |
| **OHLC Bar** | Traditional bar chart with open/close ticks |
| **Line** | Xiaolin Wu anti-aliased polyline; gaps detected by time-step |
| **Area** | Anti-aliased line + filled trapezoid gradient |
| **Volume** | Standalone full-height colour-coded volume bar chart |
| **Scatter** | Dot-per-close-price scatter plot |

### Technical indicators (computed in `.wat`)
| Indicator | Type id |
|-----------|---------|
| **SMA** – Simple Moving Average | 0 |
| **EMA** – Exponential Moving Average | 1 |
| **Bollinger Bands** (mid / upper / lower) | 2 |
| **RSI** – Relative Strength Index (Wilder smoothing) | 5 |
| **MACD** – line / signal / histogram | 6 |

RSI and MACD render in a **dedicated indicator sub-panel** (auto-enabled when the indicator is added). The sub-panel is auto-scaled to the indicator's value range.

### Axis labels
A compact **3×5 pixel font** is baked into WAT; price labels appear on the Y axis and date labels on the X axis — no dependency on canvas font rendering.

### Gap-aware rendering
Line and Area charts detect time gaps larger than 2× the expected bar step (e.g. weekend gaps in stock data) and break the polyline at those points rather than drawing misleading interpolated segments.

### Interaction
- **Scroll to zoom** (centred on cursor)
- **Drag to pan**
- **Pinch-zoom** (touch devices)
- **Crosshair** rendered in WAT, position sent from TS on `mousemove`
- **Auto-scale price** fits the Y axis to visible bars
- `hover` / `click` / `zoom` / `pan` / `resize` CustomEvents

### Data persistence (OPFS)
Datasets are serialised to tightly-packed **16/48-byte binary records** (magic `ATLCDB10`) and stored in the browser's Origin Private File System — no server required.

```ts
await chart.saveToOpfs(dsId, "btc-daily");       // writes btc-daily.bin to OPFS
const id = await chart.loadFromOpfs("btc-daily"); // reads back without re-parsing
```

---

## Quick start

```bash
bun install
bun run dev          # compiles .wat → .wasm, starts Vite dev server on :3000
```

```ts
import { AtlasChart, ChartType, IndicatorType, packRGBA } from "./src/ts/index.js";

const chart = new AtlasChart(document.querySelector("canvas")!);
await chart.init();

// Load OHLCV data
const dsId = chart.loadOhlcv(myOhlcvArray);   // [{timestamp,open,high,low,close,volume}]
chart.setActiveDataset(dsId);
chart.setChartType(ChartType.Candlestick);
chart.setShowVolume(true, 80);

// Add indicators
chart.addIndicator({ type: IndicatorType.SMA, dsId, period: 20,
                     color: packRGBA(255, 220, 50) });
chart.addIndicator({ type: IndicatorType.BB,  dsId, period: 20,
                     color: packRGBA(130, 100, 220), param1: 2.0 });
// RSI/MACD automatically open an indicator sub-panel:
chart.addIndicator({ type: IndicatorType.RSI, dsId, period: 14,
                     color: packRGBA(50, 200, 220) });

// Fit to all data and render
chart.fitToData(dsId);
```

---

## Build

```bash
bun run build:wat    # wat → public/atlas-chart.wasm  (uses wabt npm package via Bun)
bun run build:ts     # tsc type-check + vite bundle
bun run build        # both
```

### Binary format (.bin)

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 B | Magic `ATLC` (0x434C5441) |
| 4 | 4 B | Version `DB10` (0x30314244) |
| 8 | 4 B | Dataset type (0=OHLCV, 1=TimeValue) |
| 12 | 8 B | Record count (i64) |
| 20 | 8 B | Timestamp start (ms, i64) |
| 28 | 8 B | Timestamp end (ms, i64) |
| 36 | 36 B | Reserved |
| 72 | N×48 B | OHLCV records **or** N×16 B time-value records |

---

## Roadmap

- [ ] Logarithmic price scale
- [ ] Horizontal / vertical alert lines
- [ ] Multi-dataset overlay (e.g., two instruments on one chart)
- [ ] WebWorker offload for indicator computation on large datasets
- [ ] Stochastic, ATR, VWAP indicators
- [ ] Dark/light theme toggle in demo UI

