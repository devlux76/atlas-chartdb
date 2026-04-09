// Atlas ChartDB – AtlasChart: main TypeScript bridge class
//
// Bridges the HTML <canvas> element to the WebAssembly charting engine.
// The WAT module owns its framebuffer; we blit it to the canvas via
// ImageData on every render.

import type { AtlasWasmExports, OhlcvRecord, TimeValueRecord, IndicatorOptions, ViewRange } from "./types.js";
import { DatasetType, ChartType } from "./types.js";
import { loadWasm } from "./wasm-loader.js";
import { writeDatasetBin, readDatasetBin } from "./data-store.js";

export type { OhlcvRecord, TimeValueRecord, IndicatorOptions, ViewRange };
export { DatasetType, ChartType };
export { IndicatorType } from "./types.js";

// ── helpers ──────────────────────────────────────────────────────────────────

/** Pack r,g,b,a (0-255) into a single LE i32 for WAT */
export function packRGBA(r: number, g: number, b: number, a = 255): number {
  return ((a & 0xFF) * 16777216 + (b & 0xFF) * 65536 + (g & 0xFF) * 256 + (r & 0xFF)) >>> 0;
}

// Scratch pointer inside WASM memory for small data transfers (e.g. get_ohlcv_at)
const SCRATCH_PTR = 0x3100;   // start of scratch area
const LOAD_BIN_STAGING_PTR = 0x3200;
const BIN_MAGIC = 0x434C5441;
const BIN_VERSION = 0x30314244;
const BIN_HEADER_BYTES = 72;
const OHLCV_RECORD_BYTES = 48;
const TIME_VALUE_RECORD_BYTES = 16;

function packOhlcvBin(records: OhlcvRecord[]): Uint8Array {
  const buffer = new ArrayBuffer(BIN_HEADER_BYTES + records.length * OHLCV_RECORD_BYTES);
  const view = new DataView(buffer);
  const bytes = new Uint8Array(buffer);

  view.setUint32(0, BIN_MAGIC, true);
  view.setUint32(4, BIN_VERSION, true);
  view.setUint32(8, DatasetType.OHLCV, true);
  view.setBigInt64(12, BigInt(records.length), true);
  view.setBigInt64(20, BigInt(records[0]?.timestamp ?? 0), true);
  view.setBigInt64(28, BigInt(records[records.length - 1]?.timestamp ?? 0), true);

  let offset = BIN_HEADER_BYTES;
  for (const record of records) {
    view.setBigInt64(offset, BigInt(record.timestamp), true);
    view.setFloat64(offset + 8, record.open, true);
    view.setFloat64(offset + 16, record.high, true);
    view.setFloat64(offset + 24, record.low, true);
    view.setFloat64(offset + 32, record.close, true);
    view.setFloat64(offset + 40, record.volume, true);
    offset += OHLCV_RECORD_BYTES;
  }

  return bytes;
}

function packTimeValueBin(records: TimeValueRecord[]): Uint8Array {
  const buffer = new ArrayBuffer(BIN_HEADER_BYTES + records.length * TIME_VALUE_RECORD_BYTES);
  const view = new DataView(buffer);
  const bytes = new Uint8Array(buffer);

  view.setUint32(0, BIN_MAGIC, true);
  view.setUint32(4, BIN_VERSION, true);
  view.setUint32(8, DatasetType.TimeValue, true);
  view.setBigInt64(12, BigInt(records.length), true);
  view.setBigInt64(20, BigInt(records[0]?.timestamp ?? 0), true);
  view.setBigInt64(28, BigInt(records[records.length - 1]?.timestamp ?? 0), true);

  let offset = BIN_HEADER_BYTES;
  for (const record of records) {
    view.setBigInt64(offset, BigInt(record.timestamp), true);
    view.setFloat64(offset + 8, record.value, true);
    offset += TIME_VALUE_RECORD_BYTES;
  }

  return bytes;
}

// ── AtlasChart ───────────────────────────────────────────────────────────────

/**
 * AtlasChart wraps a single <canvas> element and delegates all rendering
 * to the WebAssembly engine.  You must call `await chart.init()` before
 * using any other method.
 */
export class AtlasChart extends EventTarget {
  private canvas: HTMLCanvasElement;
  private ctx: CanvasRenderingContext2D;
  private wasm!: AtlasWasmExports;
  private wasmUrl: string;
  private _ready = false;
  private _eventController: AbortController | null = null;

  // interaction state
  private _isPanning = false;
  private _panStartX = 0;
  private _panStartViewRange: ViewRange = { start: 0, end: 0 };
  private _animFrame = 0;
  private _dirty = false;

  constructor(canvas: HTMLCanvasElement, wasmUrl = "/atlas-chart.wasm") {
    super();
    this.canvas = canvas;
    this.wasmUrl = wasmUrl;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("Could not get 2D context from canvas");
    this.ctx = ctx;
  }

  // ── lifecycle ─────────────────────────────────────────────────────────────

  async init(): Promise<void> {
    this.wasm = await loadWasm(this.wasmUrl);
    this.wasm.init(this.canvas.width, this.canvas.height);
    this._attachEvents();
    this._ready = true;
  }

  get ready(): boolean { return this._ready; }

  destroy(): void {
    this._eventController?.abort();
    this._eventController = null;
    if (this._animFrame) {
      cancelAnimationFrame(this._animFrame);
      this._animFrame = 0;
    }
    this._isPanning = false;
    this._dirty = false;
    this._ready = false;
  }

  private _requireReady(): void {
    if (!this._ready) throw new Error("AtlasChart.init() has not been called yet");
  }

  private _ensureMemoryCapacity(requiredBytes: number): void {
    const memBytes = this.wasm.memory.buffer.byteLength;
    if (requiredBytes <= memBytes) return;
    const extraPages = Math.ceil((requiredBytes - memBytes) / 65536);
    this.wasm.memory.grow(extraPages);
  }

  private _loadPackedDataset(data: Uint8Array): number {
    this._requireReady();
    const requiredBytes = LOAD_BIN_STAGING_PTR + data.length;
    this._ensureMemoryCapacity(requiredBytes);
    const mem = new Uint8Array(this.wasm.memory.buffer);
    mem.set(data, LOAD_BIN_STAGING_PTR);
    return this.wasm.load_bin(LOAD_BIN_STAGING_PTR, data.length);
  }

  // ── canvas / display ──────────────────────────────────────────────────────

  resize(width: number, height: number): void {
    this._requireReady();
    this.canvas.width  = width;
    this.canvas.height = height;
    this.wasm.set_canvas_size(width, height);
    this._markDirty();
    this.dispatchEvent(new CustomEvent("resize", { detail: { width, height } }));
  }

  setTheme(bg: number, grid: number, text: number, up: number, down: number, line: number): void {
    this._requireReady();
    this.wasm.set_theme(bg, grid, text, up, down, line);
    this._markDirty();
  }

  setMargins(left: number, top: number, right: number, bottom: number): void {
    this._requireReady();
    this.wasm.set_margins(left, top, right, bottom);
    this._markDirty();
  }

  setShowVolume(show: boolean, panelH = 80): void {
    this._requireReady();
    this.wasm.set_show_volume(show ? 1 : 0, panelH);
    this._markDirty();
  }

  // ── dataset API ───────────────────────────────────────────────────────────

  /**
   * Feed a batch of OHLCV bars directly into the WASM engine.
   * Records must be in ascending timestamp order.
   */
  loadOhlcv(records: OhlcvRecord[]): number {
    const id = this._loadPackedDataset(packOhlcvBin(records));
    if (id < 0) throw new Error("Failed to load OHLCV dataset into Wasm");
    return id;
  }

  /**
   * Feed a batch of time-value records.
   * Records must be in ascending timestamp order.
   */
  loadTimeValue(records: TimeValueRecord[]): number {
    const id = this._loadPackedDataset(packTimeValueBin(records));
    if (id < 0) throw new Error("Failed to load time-value dataset into Wasm");
    return id;
  }

  /**
   * Load a dataset from an OPFS .bin file by name.
   * Returns the dataset id, or -1 if the file does not exist.
   */
  async loadFromOpfs(name: string): Promise<number> {
    this._requireReady();
    const data = await readDatasetBin(name);
    if (!data) return -1;
    return this._loadPackedDataset(data);
  }

  /**
   * Persist a loaded dataset back to OPFS as a .bin file.
   */
  async saveToOpfs(dsId: number, name: string): Promise<void> {
    this._requireReady();
    const cnt  = this.wasm.get_ds_record_count(dsId);
    const maxRecordBytes = Math.max(OHLCV_RECORD_BYTES, TIME_VALUE_RECORD_BYTES);
    const required = LOAD_BIN_STAGING_PTR + BIN_HEADER_BYTES + cnt * maxRecordBytes;
    this._ensureMemoryCapacity(required);
    const written = this.wasm.serialize_dataset(dsId, LOAD_BIN_STAGING_PTR);
    if (written < 0) throw new Error(`serialize_dataset returned ${written}`);
    const mem   = new Uint8Array(this.wasm.memory.buffer);
    const slice = mem.slice(LOAD_BIN_STAGING_PTR, LOAD_BIN_STAGING_PTR + written);
    await writeDatasetBin(name, slice);
  }

  // ── active chart controls ─────────────────────────────────────────────────

  setActiveDataset(dsId: number): void {
    this._requireReady();
    this.wasm.set_active_ds(dsId);
    this._markDirty();
  }

  setChartType(type: ChartType): void {
    this._requireReady();
    this.wasm.set_chart_type(type);
    this._markDirty();
  }

  setViewRange(range: ViewRange): void {
    this._requireReady();
    this.wasm.set_view_range(BigInt(range.start), BigInt(range.end));
    this._markDirty();
  }

  getViewRange(): ViewRange {
    this._requireReady();
    return this._getViewRange();
  }

  autoScalePrice(): void {
    this._requireReady();
    this.wasm.auto_scale_price();
    this._markDirty();
  }

  setPriceRange(min: number, max: number): void {
    this._requireReady();
    this.wasm.set_price_range(min, max);
    this._markDirty();
  }

  getPriceRange(): { min: number; max: number } {
    this._requireReady();
    return {
      min: this.wasm.get_price_min(),
      max: this.wasm.get_price_max(),
    };
  }

  fitToData(dsId?: number): void {
    this._requireReady();
    const id = dsId ?? this.wasm.get_ds_count() - 1;
    if (id < 0) return;
    const s = Number(this.wasm.get_ds_time_start(id));
    const e = Number(this.wasm.get_ds_time_end(id));
    this.wasm.set_view_range(BigInt(s), BigInt(e));
    this.wasm.auto_scale_price();
    this._markDirty();
  }

  // ── indicators ────────────────────────────────────────────────────────────

  addIndicator(opts: IndicatorOptions): number {
    this._requireReady();
    const id = this.wasm.add_indicator(
      opts.type, opts.dsId, opts.period, opts.color,
      opts.param1 ?? 0, opts.param2 ?? 0, opts.param3 ?? 0,
    );
    this.wasm.compute_indicators();
    // Auto-show the indicator sub-panel for RSI (5) and MACD (6)
    if (opts.type === 5 || opts.type === 6) {
      this.wasm.set_ind_panel(1, 70);
      this.wasm.auto_scale_ind_panel();
    }
    this._markDirty();
    return id;
  }

  /** Manually configure the indicator sub-panel height; pass show=false to hide it. */
  setIndicatorPanel(show: boolean, height = 70): void {
    this._requireReady();
    this.wasm.set_ind_panel(show ? 1 : 0, height);
    this._markDirty();
  }

  removeIndicator(indId: number): void {
    this._requireReady();
    this.wasm.remove_indicator(indId);
    this._markDirty();
  }

  recomputeIndicators(): void {
    this._requireReady();
    this.wasm.compute_indicators();
    this._markDirty();
  }

  // ── data query ────────────────────────────────────────────────────────────

  getRecordCount(dsId: number): number {
    this._requireReady();
    return this.wasm.get_ds_record_count(dsId);
  }

  getOhlcvAt(dsId: number, idx: number): OhlcvRecord | null {
    this._requireReady();
    const ptr = SCRATCH_PTR;
    const res = this.wasm.get_ohlcv_at(dsId, idx, ptr);
    if (res < 0) return null;
    const view = new DataView(this.wasm.memory.buffer);
    return {
      timestamp: Number(view.getBigInt64(ptr,      true)),
      open:      view.getFloat64(ptr + 8,  true),
      high:      view.getFloat64(ptr + 16, true),
      low:       view.getFloat64(ptr + 24, true),
      close:     view.getFloat64(ptr + 32, true),
      volume:    view.getFloat64(ptr + 40, true),
    };
  }

  // ── rendering ─────────────────────────────────────────────────────────────

  /**
   * Render the current state immediately (synchronous blit).
   * Usually you do not need to call this directly — the chart is
   * auto-rendered whenever the state changes.
   */
  render(): void {
    this._requireReady();
    this.wasm.clear();
    this.wasm.render_chart();
    this._blit();
    this._dirty = false;
  }

  private _blit(): void {
    const w = this.canvas.width;
    const h = this.canvas.height;
    const ptr  = this.wasm.get_fb_ptr();
    const size = this.wasm.get_fb_size();
    const raw  = new Uint8ClampedArray(this.wasm.memory.buffer, ptr, size);
    const imageData = new ImageData(raw, w, h);
    this.ctx.putImageData(imageData, 0, 0);
  }

  private _markDirty(): void {
    this._dirty = true;
    if (!this._animFrame) {
      this._animFrame = requestAnimationFrame(() => {
        this._animFrame = 0;
        if (this._dirty) this.render();
      });
    }
  }

  // ── event handling ────────────────────────────────────────────────────────

  private _attachEvents(): void {
    this._eventController?.abort();
    this._eventController = new AbortController();
    const signal = this._eventController.signal;

    this.canvas.addEventListener("mousemove", this._onMouseMove.bind(this), { signal });
    this.canvas.addEventListener("mouseleave", this._onMouseLeave.bind(this), { signal });
    this.canvas.addEventListener("mousedown", this._onMouseDown.bind(this), { signal });
    window.addEventListener("mouseup", this._onMouseUp.bind(this), { signal });
    this.canvas.addEventListener("click", this._onClick.bind(this), { signal });
    this.canvas.addEventListener("wheel", this._onWheel.bind(this), { passive: false, signal });
    this.canvas.addEventListener("touchstart", this._onTouchStart.bind(this), { passive: false, signal });
    this.canvas.addEventListener("touchmove", this._onTouchMove.bind(this), { passive: false, signal });
    this.canvas.addEventListener("touchend", this._onTouchEnd.bind(this), { signal });
  }

  private _canvasXY(e: MouseEvent | Touch): { x: number; y: number } {
    const r = this.canvas.getBoundingClientRect();
    const scaleX = r.width  > 0 ? this.canvas.width  / r.width  : 1;
    const scaleY = r.height > 0 ? this.canvas.height / r.height : 1;
    return {
      x: Math.round((e.clientX - r.left) * scaleX),
      y: Math.round((e.clientY - r.top)  * scaleY),
    };
  }

  private _onMouseMove(e: MouseEvent): void {
    const { x, y } = this._canvasXY(e);
    this.wasm.set_crosshair(x, y);
    const index = this.wasm.hit_test(x, y);
    const ts    = Number(this.wasm.x_to_time_export(x));
    const price = this.wasm.y_to_price_export(y);
    this.dispatchEvent(new CustomEvent("hover", { detail: { x, y, index, ts, price } }));
    if (this._isPanning) {
      this._doPan(x);
    }
    this._markDirty();
  }

  private _onMouseLeave(): void {
    this.wasm.set_crosshair(-1, -1);
    this._markDirty();
  }

  private _onMouseDown(e: MouseEvent): void {
    if (e.button !== 0) return;
    const { x } = this._canvasXY(e);
    this._isPanning = true;
    this._panStartX = x;
    this._panStartViewRange = this._getViewRange();
    this.canvas.style.cursor = "grabbing";
  }

  private _onMouseUp(): void {
    this._isPanning = false;
    this.canvas.style.cursor = "";
  }

  private _onClick(e: MouseEvent): void {
    const { x, y } = this._canvasXY(e);
    const index = this.wasm.hit_test(x, y);
    const ts    = Number(this.wasm.x_to_time_export(x));
    const price = this.wasm.y_to_price_export(y);
    this.dispatchEvent(new CustomEvent("click", { detail: { x, y, index, ts, price } }));
  }

  private _onWheel(e: WheelEvent): void {
    e.preventDefault();
    const { x } = this._canvasXY(e);
    const factor = e.deltaY > 0 ? 1.1 : 0.9;
    this._zoomAroundX(x, factor);
  }

  // pinch-zoom touch support
  private _lastTouchDist = 0;

  private _onTouchStart(e: TouchEvent): void {
    e.preventDefault();
    if (e.touches.length === 2) {
      const dx = e.touches[1].clientX - e.touches[0].clientX;
      const dy = e.touches[1].clientY - e.touches[0].clientY;
      this._lastTouchDist = Math.hypot(dx, dy);
    } else if (e.touches.length === 1) {
      const { x } = this._canvasXY(e.touches[0]);
      this._isPanning   = true;
      this._panStartX   = x;
      this._panStartViewRange = this._getViewRange();
    }
  }

  private _onTouchMove(e: TouchEvent): void {
    e.preventDefault();
    if (e.touches.length === 2) {
      const dx = e.touches[1].clientX - e.touches[0].clientX;
      const dy = e.touches[1].clientY - e.touches[0].clientY;
      const dist = Math.hypot(dx, dy);
      const factor = this._lastTouchDist / dist;
      const midX = (e.touches[0].clientX + e.touches[1].clientX) / 2
                   - this.canvas.getBoundingClientRect().left;
      this._zoomAroundX(midX, factor);
      this._lastTouchDist = dist;
    } else if (e.touches.length === 1 && this._isPanning) {
      const { x } = this._canvasXY(e.touches[0]);
      this._doPan(x);
    }
  }

  private _onTouchEnd(_e: TouchEvent): void {
    this._isPanning = false;
  }

  // ── pan / zoom helpers ────────────────────────────────────────────────────

  private _getViewRange(): ViewRange {
    return {
      start: Number(this.wasm.get_view_start()),
      end: Number(this.wasm.get_view_end()),
    };
  }

  private _doPan(currentX: number): void {
    const dx   = currentX - this._panStartX;
    const w    = this.canvas.width;
    const r    = this._panStartViewRange;
    const span = r.end - r.start;
    if (w <= 0) return;
    const shift = Math.round((dx / w) * span);
    this.wasm.set_view_range(BigInt(r.start - shift), BigInt(r.end - shift));
    this._markDirty();
    this.dispatchEvent(new CustomEvent("pan", { detail: this._getViewRange() }));
  }

  private _zoomAroundX(pivotX: number, factor: number): void {
    const r   = this._getViewRange();
    const ts  = Number(this.wasm.x_to_time_export(pivotX));
    const newStart = Math.round(ts - (ts - r.start) * factor);
    const newEnd   = Math.round(ts + (r.end   - ts) * factor);
    this.wasm.set_view_range(BigInt(newStart), BigInt(newEnd));
    this.wasm.auto_scale_price();
    this._markDirty();
    this.dispatchEvent(new CustomEvent("zoom", { detail: { start: newStart, end: newEnd } }));
  }
}
