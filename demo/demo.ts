// Atlas ChartDB – interactive demo
// Demonstrates all chart types: Candlestick, Line, Area, OHLC Bar, Volume, Scatter
// Plus indicators: SMA, EMA, Bollinger Bands, RSI, MACD

import { AtlasChart, packRGBA, ChartType, IndicatorType } from "../src/ts/index.js";

const WASM_URL = "/atlas-chart.wasm";
const W = 560;
const H = 320;

// ── synthetic data generation ────────────────────────────────────────────────

function generateOhlcv(
  n: number,
  startPrice = 100,
  startTs = Date.now() - n * 24 * 3600_000,
) {
  const records = [];
  let price = startPrice;
  for (let i = 0; i < n; i++) {
    const ts = startTs + i * 24 * 3600_000;
    const change = (Math.random() - 0.49) * price * 0.03;
    const open   = price;
    price += change;
    const close = price;
    const high  = Math.max(open, close) * (1 + Math.random() * 0.02);
    const low   = Math.min(open, close) * (1 - Math.random() * 0.02);
    const vol   = 500_000 + Math.random() * 1_500_000;
    records.push({ timestamp: ts, open, high, low, close, volume: vol });
  }
  return records;
}

// ── chart card factory ────────────────────────────────────────────────────────

function createCard(title: string): { canvas: HTMLCanvasElement; info: HTMLElement } {
  const card   = document.createElement("div");
  card.className = "chart-card";
  const hdr    = document.createElement("header");
  hdr.textContent = title;
  const canvas = document.createElement("canvas");
  canvas.width  = W;
  canvas.height = H;
  canvas.style.height = `${H}px`;
  const info   = document.createElement("div");
  info.className = "info-bar";
  card.appendChild(hdr);
  card.appendChild(canvas);
  card.appendChild(info);
  document.getElementById("chartGrid")!.appendChild(card);
  return { canvas, info };
}

// ── theme presets ─────────────────────────────────────────────────────────────

const DARK_THEME = {
  bg:   packRGBA(26,  26,  46,  255),
  grid: packRGBA(64,  64,  80,  128),
  text: packRGBA(200, 200, 220, 255),
  up:   packRGBA(38,  166, 154, 255),
  down: packRGBA(239, 83,  80,  255),
  line: packRGBA(33,  150, 243, 255),
};

// ── indicator colours ─────────────────────────────────────────────────────────

const COL_SMA20   = packRGBA(255, 220,  50, 220);
const COL_EMA9    = packRGBA(255, 140,  50, 220);
const COL_BB      = packRGBA(130, 100, 220, 200);
const COL_RSI     = packRGBA( 50, 200, 220, 230);
const COL_MACD    = packRGBA( 80, 200,  80, 230);

// ── build a chart card and attach hover info ──────────────────────────────────

async function makeChart(
  title: string,
  type: ChartType,
  records: ReturnType<typeof generateOhlcv>,
  extraSetup?: (chart: AtlasChart, dsId: number) => void,
): Promise<AtlasChart> {
  const { canvas, info } = createCard(title);
  const chart = new AtlasChart(canvas, WASM_URL);
  await chart.init();
  chart.setTheme(
    DARK_THEME.bg, DARK_THEME.grid, DARK_THEME.text,
    DARK_THEME.up, DARK_THEME.down, DARK_THEME.line,
  );
  chart.setMargins(52, 16, 16, 32);
  const dsId = chart.loadOhlcv(records);
  chart.setActiveDataset(dsId);
  chart.setChartType(type);
  chart.setShowVolume(
    type === ChartType.Candlestick || type === ChartType.OhlcBar, 60,
  );
  if (extraSetup) extraSetup(chart, dsId);
  chart.fitToData(dsId);
  chart.render();

  // hover info
  chart.addEventListener("hover", (e: Event) => {
    const { index, ts, price } = (e as CustomEvent).detail as { index: number; ts: number; price: number };
    if (index < 0) { info.textContent = ""; return; }
    const r = chart.getOhlcvAt(dsId, index);
    if (!r) { info.textContent = `T: ${new Date(ts).toLocaleDateString()}  Price: ${price.toFixed(2)}`; return; }
    info.textContent =
      `${new Date(r.timestamp).toLocaleDateString()}  ` +
      `O:${r.open.toFixed(2)}  H:${r.high.toFixed(2)}  L:${r.low.toFixed(2)}  C:${r.close.toFixed(2)}  ` +
      `Vol:${(r.volume / 1e6).toFixed(2)}M`;
  });

  return chart;
}

// ── main ──────────────────────────────────────────────────────────────────────

const allCharts: AtlasChart[] = [];
let ohlcvData = generateOhlcv(120);

async function buildAll() {
  const grid = document.getElementById("chartGrid")!;
  grid.innerHTML = "";
  allCharts.length = 0;

  // 1. Candlestick + Volume + SMA20 + BB
  allCharts.push(await makeChart(
    "Candlestick  +  SMA 20  +  Bollinger Bands  +  Volume",
    ChartType.Candlestick,
    ohlcvData,
    (chart, dsId) => {
      chart.addIndicator({ type: IndicatorType.SMA,  dsId, period: 20, color: COL_SMA20 });
      chart.addIndicator({ type: IndicatorType.BB,   dsId, period: 20, color: COL_BB, param1: 2.0 });
    },
  ));

  // 2. OHLC Bar + EMA 9
  allCharts.push(await makeChart(
    "OHLC Bar  +  EMA 9",
    ChartType.OhlcBar,
    ohlcvData,
    (chart, dsId) => {
      chart.addIndicator({ type: IndicatorType.EMA, dsId, period: 9, color: COL_EMA9 });
    },
  ));

  // 3. Line chart + RSI (renders RSI on the same panel using price-space mapping)
  allCharts.push(await makeChart(
    "Line Chart  +  RSI 14",
    ChartType.Line,
    ohlcvData,
    (chart, dsId) => {
      chart.addIndicator({ type: IndicatorType.RSI, dsId, period: 14, color: COL_RSI });
    },
  ));

  // 4. Area chart + MACD
  allCharts.push(await makeChart(
    "Area Chart  +  MACD (12, 26, 9)",
    ChartType.Area,
    ohlcvData,
    (chart, dsId) => {
      chart.addIndicator({
        type: IndicatorType.MACD, dsId, period: 1, color: COL_MACD,
        param1: 12, param2: 26, param3: 9,
      });
    },
  ));

  // 5. Volume-only chart
  allCharts.push(await makeChart(
    "Volume bars (standalone)",
    ChartType.Volume,
    ohlcvData,
    (chart) => { chart.setShowVolume(false); },
  ));

  // 6. Scatter + SMA 10
  allCharts.push(await makeChart(
    "Scatter (close prices)  +  SMA 10",
    ChartType.Scatter,
    ohlcvData,
    (chart, dsId) => {
      chart.addIndicator({
        type: IndicatorType.SMA, dsId, period: 10,
        color: packRGBA(255, 180, 60, 220),
      });
    },
  ));

  document.getElementById("statusBar")!.textContent =
    `✅  ${allCharts.length} charts rendered  ·  ${ohlcvData.length} bars  ·  WebAssembly active`;
}

// ── controls ──────────────────────────────────────────────────────────────────

document.getElementById("btnRegenerate")!.addEventListener("click", () => {
  const n = parseInt((document.getElementById("barsSelect") as HTMLSelectElement).value);
  ohlcvData = generateOhlcv(n);
  buildAll();
});

document.getElementById("barsSelect")!.addEventListener("change", () => {
  const n = parseInt((document.getElementById("barsSelect") as HTMLSelectElement).value);
  ohlcvData = generateOhlcv(n);
  buildAll();
});

document.getElementById("btnSaveOpfs")!.addEventListener("click", async () => {
  const chart = allCharts[0];
  if (!chart) return;
  await chart.saveToOpfs(0, "demo-ohlcv");
  document.getElementById("statusBar")!.textContent = "💾  Saved dataset 0 to OPFS as demo-ohlcv.bin";
});

document.getElementById("btnLoadOpfs")!.addEventListener("click", async () => {
  const { canvas, info } = createCard("Loaded from OPFS");
  const chart = new AtlasChart(canvas, WASM_URL);
  await chart.init();
  chart.setTheme(
    DARK_THEME.bg, DARK_THEME.grid, DARK_THEME.text,
    DARK_THEME.up, DARK_THEME.down, DARK_THEME.line,
  );
  chart.setMargins(52, 16, 16, 32);
  const dsId = await chart.loadFromOpfs("demo-ohlcv");
  if (dsId < 0) {
    info.textContent = "⚠ demo-ohlcv.bin not found in OPFS. Click 'Save to OPFS' first.";
    chart.render();
    return;
  }
  chart.setActiveDataset(dsId);
  chart.setChartType(ChartType.Candlestick);
  chart.setShowVolume(true, 60);
  chart.fitToData(dsId);
  chart.render();
  info.textContent = `Loaded ${chart.getRecordCount(dsId)} bars from OPFS`;
  allCharts.push(chart);
  document.getElementById("statusBar")!.textContent =
    "📂  Loaded demo-ohlcv.bin from OPFS";
});

// kick-off
buildAll();
