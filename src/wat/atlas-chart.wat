;; atlas-chart.wat — Atlas ChartDB WebAssembly Charting Engine
;;
;; Memory layout:
;;   0x000000 – 0x0000FF : Config header (256 B)
;;   0x000100 – 0x0020FF : Dataset registry (32 × 256 B)
;;   0x002100 – 0x0030FF : Indicator registry (16 × 256 B)
;;   0x003100 – 0x00FFFF : Scratch buffer (~53 KB)
;;   0x010000 – 0x80FFFF : Framebuffer (≤ 2048×1024 RGBA = 8 MB)
;;   0x810000 – …        : Dataset + indicator value storage

(module
  (memory (export "memory") 256 512)

  ;; ── mutable globals ──────────────────────────────────────────────────
  ;; next free byte in data+indicator storage
  (global $g_stor_cur (mut i32) (i32.const 0x810000))

  ;; ── helpers: math ────────────────────────────────────────────────────
  (func $min_i32 (param $a i32) (param $b i32) (result i32)
    (select (local.get $a) (local.get $b) (i32.lt_s (local.get $a) (local.get $b))))

  (func $max_i32 (param $a i32) (param $b i32) (result i32)
    (select (local.get $a) (local.get $b) (i32.gt_s (local.get $a) (local.get $b))))

  (func $clamp_i32 (param $v i32) (param $lo i32) (param $hi i32) (result i32)
    (call $max_i32 (local.get $lo) (call $min_i32 (local.get $v) (local.get $hi))))

  (func $abs_i32 (param $x i32) (result i32)
    (select (local.get $x) (i32.sub (i32.const 0) (local.get $x))
      (i32.ge_s (local.get $x) (i32.const 0))))

  (func $min_f64 (param $a f64) (param $b f64) (result f64)
    (select (local.get $a) (local.get $b) (f64.lt (local.get $a) (local.get $b))))

  (func $max_f64 (param $a f64) (param $b f64) (result f64)
    (select (local.get $a) (local.get $b) (f64.gt (local.get $a) (local.get $b))))

  (func $abs_f64 (param $x f64) (result f64)
    (select (local.get $x) (f64.neg (local.get $x)) (f64.ge (local.get $x) (f64.const 0))))

  ;; ── helpers: color ───────────────────────────────────────────────────
  ;; Packed color: LE i32 with bytes R,G,B,A  → (A<<24)|(B<<16)|(G<<8)|R
  (func $pack_rgba (param $r i32) (param $g i32) (param $b i32) (param $a i32) (result i32)
    (i32.or
      (i32.or (i32.shl (local.get $a) (i32.const 24))
              (i32.shl (local.get $b) (i32.const 16)))
      (i32.or (i32.shl (local.get $g) (i32.const 8))
              (local.get $r))))

  (func $ch_r (param $c i32) (result i32) (i32.and (local.get $c) (i32.const 0xFF)))
  (func $ch_g (param $c i32) (result i32) (i32.and (i32.shr_u (local.get $c) (i32.const 8))  (i32.const 0xFF)))
  (func $ch_b (param $c i32) (result i32) (i32.and (i32.shr_u (local.get $c) (i32.const 16)) (i32.const 0xFF)))
  (func $ch_a (param $c i32) (result i32) (i32.and (i32.shr_u (local.get $c) (i32.const 24)) (i32.const 0xFF)))

  ;; Porter-Duff "src over dst" alpha blend
  (func $blend_over (param $dst i32) (param $src i32) (result i32)
    (local $sa i32) (local $isa i32)
    (local.set $sa  (call $ch_a (local.get $src)))
    (local.set $isa (i32.sub (i32.const 255) (local.get $sa)))
    (call $pack_rgba
      (i32.shr_u (i32.add (i32.mul (call $ch_r (local.get $src)) (local.get $sa))
                          (i32.mul (call $ch_r (local.get $dst)) (local.get $isa))) (i32.const 8))
      (i32.shr_u (i32.add (i32.mul (call $ch_g (local.get $src)) (local.get $sa))
                          (i32.mul (call $ch_g (local.get $dst)) (local.get $isa))) (i32.const 8))
      (i32.shr_u (i32.add (i32.mul (call $ch_b (local.get $src)) (local.get $sa))
                          (i32.mul (call $ch_b (local.get $dst)) (local.get $isa))) (i32.const 8))
      (i32.const 255)))

  ;; ── config accessors (inline helpers, keep code readable) ────────────
  (func $cw  (result i32) (i32.load offset=0  (i32.const 0)))
  (func $ch  (result i32) (i32.load offset=4  (i32.const 0)))
  (func $cx  (result i32) (i32.load offset=8  (i32.const 0)))
  (func $cy  (result i32) (i32.load offset=12 (i32.const 0)))
  (func $caw (result i32) (i32.load offset=16 (i32.const 0)))
  (func $cah (result i32) (i32.load offset=20 (i32.const 0)))
  (func $active_ds  (result i32) (i32.load offset=24 (i32.const 0)))
  (func $chart_type (result i32) (i32.load offset=28 (i32.const 0)))
  (func $view_s (result i64) (i64.load offset=32 (i32.const 0)))
  (func $view_e (result i64) (i64.load offset=40 (i32.const 0)))
  (func $pmin   (result f64) (f64.load offset=48 (i32.const 0)))
  (func $pmax   (result f64) (f64.load offset=56 (i32.const 0)))
  (func $bg_col   (result i32) (i32.load offset=64 (i32.const 0)))
  (func $grid_col (result i32) (i32.load offset=68 (i32.const 0)))
  (func $up_col   (result i32) (i32.load offset=72 (i32.const 0)))
  (func $dn_col   (result i32) (i32.load offset=76 (i32.const 0)))
  (func $ln_col   (result i32) (i32.load offset=80 (i32.const 0)))
  (func $ds_count (result i32) (i32.load offset=88 (i32.const 0)))
  (func $ind_count (result i32) (i32.load offset=92 (i32.const 0)))
  (func $ml (result i32) (i32.load offset=112 (i32.const 0)))
  (func $mt (result i32) (i32.load offset=116 (i32.const 0)))
  (func $mr (result i32) (i32.load offset=120 (i32.const 0)))
  (func $mb (result i32) (i32.load offset=124 (i32.const 0)))
  (func $show_vol  (result i32) (i32.load offset=136 (i32.const 0)))
  (func $vol_h     (result i32) (i32.load offset=140 (i32.const 0)))
  ;; indicator sub-panel
  (func $ind_ps   (result i32) (i32.load  offset=144 (i32.const 0))) ;; show indicator panel
  (func $ind_ph   (result i32) (i32.load  offset=148 (i32.const 0))) ;; indicator panel height
  (func $ind_pmin (result f64) (f64.load  offset=152 (i32.const 0))) ;; indicator panel y min
  (func $ind_pmax (result f64) (f64.load  offset=160 (i32.const 0))) ;; indicator panel y max
  ;; text colour (set by set_theme as the $text parameter, stored at offset 84)
  (func $text_col (result i32) (i32.load  offset=84  (i32.const 0)))

  (func $recalc_chart_area
    (i32.store offset=8  (i32.const 0) (call $ml))
    (i32.store offset=12 (i32.const 0) (call $mt))
    (i32.store offset=16 (i32.const 0)
      (i32.sub (i32.sub (call $cw) (call $ml)) (call $mr)))
    (i32.store offset=20 (i32.const 0)
      (i32.sub (i32.sub (i32.sub (i32.sub
        (call $ch) (call $mt)) (call $mb))
        (select (call $vol_h) (i32.const 0) (call $show_vol)))
        (select (call $ind_ph) (i32.const 0) (call $ind_ps)))))

  ;; ── framebuffer ──────────────────────────────────────────────────────
  (func $fb_off (param $x i32) (param $y i32) (result i32)
    (i32.add (i32.const 0x010000)
      (i32.shl (i32.add (i32.mul (local.get $y) (call $cw)) (local.get $x)) (i32.const 2))))

  (func $fb_get (param $x i32) (param $y i32) (result i32)
    (i32.load (call $fb_off (local.get $x) (local.get $y))))

  (func $fb_set (param $x i32) (param $y i32) (param $c i32)
    (i32.store (call $fb_off (local.get $x) (local.get $y)) (local.get $c)))

  (func $fb_set_s (param $x i32) (param $y i32) (param $c i32)
    (if (i32.and
          (i32.and (i32.ge_s (local.get $x) (i32.const 0))
                   (i32.lt_s (local.get $x) (call $cw)))
          (i32.and (i32.ge_s (local.get $y) (i32.const 0))
                   (i32.lt_s (local.get $y) (call $ch))))
      (then (call $fb_set (local.get $x) (local.get $y) (local.get $c)))))

  (func $fb_blend (param $x i32) (param $y i32) (param $c i32)
    (if (i32.and
          (i32.and (i32.ge_s (local.get $x) (i32.const 0))
                   (i32.lt_s (local.get $x) (call $cw)))
          (i32.and (i32.ge_s (local.get $y) (i32.const 0))
                   (i32.lt_s (local.get $y) (call $ch))))
      (then
        (call $fb_set (local.get $x) (local.get $y)
          (call $blend_over
            (call $fb_get (local.get $x) (local.get $y))
            (local.get $c))))))

  ;; ── drawing primitives ───────────────────────────────────────────────
  (func $draw_hline (param $x1 i32) (param $x2 i32) (param $y i32) (param $col i32)
    (local $x i32)
    (if (i32.or (i32.lt_s (local.get $y) (i32.const 0))
                (i32.ge_s (local.get $y) (call $ch))) (then (return)))
    (local.set $x (call $max_i32 (local.get $x1) (i32.const 0)))
    (block $brk (loop $lp
      (br_if $brk (i32.gt_s (local.get $x)
        (call $min_i32 (local.get $x2) (i32.sub (call $cw) (i32.const 1)))))
      (call $fb_set (local.get $x) (local.get $y) (local.get $col))
      (local.set $x (i32.add (local.get $x) (i32.const 1)))
      (br $lp))))

  (func $draw_vline (param $x i32) (param $y1 i32) (param $y2 i32) (param $col i32)
    (local $y i32)
    (if (i32.or (i32.lt_s (local.get $x) (i32.const 0))
                (i32.ge_s (local.get $x) (call $cw))) (then (return)))
    (local.set $y (call $max_i32 (local.get $y1) (i32.const 0)))
    (block $brk (loop $lp
      (br_if $brk (i32.gt_s (local.get $y)
        (call $min_i32 (local.get $y2) (i32.sub (call $ch) (i32.const 1)))))
      (call $fb_set (local.get $x) (local.get $y) (local.get $col))
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br $lp))))

  (func $draw_rect (param $x i32) (param $y i32) (param $w i32) (param $h i32) (param $col i32)
    (local $row i32) (local $x2 i32) (local $y2 i32)
    (local.set $x2 (i32.sub (i32.add (local.get $x) (local.get $w)) (i32.const 1)))
    (local.set $y2 (i32.sub (i32.add (local.get $y) (local.get $h)) (i32.const 1)))
    (local.set $row (local.get $y))
    (block $brk (loop $lp
      (br_if $brk (i32.gt_s (local.get $row) (local.get $y2)))
      (call $draw_hline (local.get $x) (local.get $x2) (local.get $row) (local.get $col))
      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br $lp))))

  (func $draw_rect_outline (param $x i32) (param $y i32) (param $w i32) (param $h i32) (param $col i32)
    (local $x2 i32) (local $y2 i32)
    (local.set $x2 (i32.sub (i32.add (local.get $x) (local.get $w)) (i32.const 1)))
    (local.set $y2 (i32.sub (i32.add (local.get $y) (local.get $h)) (i32.const 1)))
    (call $draw_hline (local.get $x) (local.get $x2) (local.get $y)  (local.get $col))
    (call $draw_hline (local.get $x) (local.get $x2) (local.get $y2) (local.get $col))
    (call $draw_vline (local.get $x)  (local.get $y) (local.get $y2) (local.get $col))
    (call $draw_vline (local.get $x2) (local.get $y) (local.get $y2) (local.get $col)))

  ;; Bresenham line
  (func $draw_line (param $x0 i32) (param $y0 i32) (param $x1 i32) (param $y1 i32) (param $col i32)
    (local $dx i32) (local $dy i32) (local $sx i32) (local $sy i32)
    (local $err i32) (local $e2 i32)
    (local.set $dx (call $abs_i32 (i32.sub (local.get $x1) (local.get $x0))))
    (local.set $dy (call $abs_i32 (i32.sub (local.get $y1) (local.get $y0))))
    (local.set $sx (select (i32.const 1) (i32.const -1)
      (i32.lt_s (local.get $x0) (local.get $x1))))
    (local.set $sy (select (i32.const 1) (i32.const -1)
      (i32.lt_s (local.get $y0) (local.get $y1))))
    (local.set $err (i32.sub (local.get $dx) (local.get $dy)))
    (block $done (loop $step
      (call $fb_set_s (local.get $x0) (local.get $y0) (local.get $col))
      (br_if $done (i32.and (i32.eq (local.get $x0) (local.get $x1))
                            (i32.eq (local.get $y0) (local.get $y1))))
      (local.set $e2 (i32.shl (local.get $err) (i32.const 1)))
      (if (i32.gt_s (local.get $e2) (i32.sub (i32.const 0) (local.get $dy)))
        (then
          (local.set $err (i32.sub (local.get $err) (local.get $dy)))
          (local.set $x0  (i32.add (local.get $x0)  (local.get $sx)))))
      (if (i32.lt_s (local.get $e2) (local.get $dx))
        (then
          (local.set $err (i32.add (local.get $err) (local.get $dx)))
          (local.set $y0  (i32.add (local.get $y0)  (local.get $sy)))))
      (br $step))))

  ;; Xiaolin Wu anti-aliased line
  (func $draw_aa_line
    (param $x0 i32) (param $y0 i32) (param $x1 i32) (param $y1 i32)
    (param $r i32) (param $g i32) (param $b i32)
    (local $dx i32) (local $dy i32) (local $steep i32) (local $tmp i32)
    (local $grad f64) (local $intery f64)
    (local $xend f64) (local $yend f64) (local $ygap f64)
    (local $xp1 i32) (local $yp1 i32) (local $xp2 i32) (local $yp2 i32)
    (local $a1 i32) (local $a2 i32) (local $ix i32)
    (local $fx0 f64) (local $fy0 f64) (local $fx1 f64) (local $fy1 f64)
    (local $frac f64)
    (local.set $dx (i32.sub (local.get $x1) (local.get $x0)))
    (local.set $dy (i32.sub (local.get $y1) (local.get $y0)))
    (local.set $steep
      (i32.gt_s (call $abs_i32 (local.get $dy)) (call $abs_i32 (local.get $dx))))
    (if (local.get $steep)
      (then
        (local.set $tmp (local.get $x0)) (local.set $x0 (local.get $y0)) (local.set $y0 (local.get $tmp))
        (local.set $tmp (local.get $x1)) (local.set $x1 (local.get $y1)) (local.set $y1 (local.get $tmp))))
    (if (i32.gt_s (local.get $x0) (local.get $x1))
      (then
        (local.set $tmp (local.get $x0)) (local.set $x0 (local.get $x1)) (local.set $x1 (local.get $tmp))
        (local.set $tmp (local.get $y0)) (local.set $y0 (local.get $y1)) (local.set $y1 (local.get $tmp))))
    (local.set $fx0 (f64.convert_i32_s (local.get $x0)))
    (local.set $fy0 (f64.convert_i32_s (local.get $y0)))
    (local.set $fx1 (f64.convert_i32_s (local.get $x1)))
    (local.set $fy1 (f64.convert_i32_s (local.get $y1)))
    (local.set $dx  (i32.sub (local.get $x1) (local.get $x0)))
    (local.set $dy  (i32.sub (local.get $y1) (local.get $y0)))
    (local.set $grad (select
      (f64.div (f64.convert_i32_s (local.get $dy)) (f64.convert_i32_s (local.get $dx)))
      (f64.const 1.0)
      (i32.ne (local.get $dx) (i32.const 0))))
    ;; first endpoint
    (local.set $xend (f64.nearest (local.get $fx0)))
    (local.set $yend (f64.add (local.get $fy0)
      (f64.mul (local.get $grad) (f64.sub (local.get $xend) (local.get $fx0)))))
    (local.set $ygap (f64.sub (f64.const 1.0)
      (f64.sub (f64.add (local.get $fx0) (f64.const 0.5))
               (f64.floor (f64.add (local.get $fx0) (f64.const 0.5))))))
    (local.set $xp1 (i32.trunc_sat_f64_s (local.get $xend)))
    (local.set $yp1 (i32.trunc_sat_f64_s (f64.floor (local.get $yend))))
    (local.set $frac (f64.sub (local.get $yend) (f64.floor (local.get $yend))))
    (local.set $a1 (i32.trunc_sat_f64_s
      (f64.mul (f64.sub (f64.const 1.0) (local.get $frac))
               (f64.mul (local.get $ygap) (f64.const 255.0)))))
    (local.set $a2 (i32.trunc_sat_f64_s
      (f64.mul (local.get $frac)
               (f64.mul (local.get $ygap) (f64.const 255.0)))))
    (if (local.get $steep)
      (then
        (call $fb_blend (local.get $yp1) (local.get $xp1)
          (call $pack_rgba (local.get $r) (local.get $g) (local.get $b) (local.get $a1)))
        (call $fb_blend (i32.add (local.get $yp1) (i32.const 1)) (local.get $xp1)
          (call $pack_rgba (local.get $r) (local.get $g) (local.get $b) (local.get $a2))))
      (else
        (call $fb_blend (local.get $xp1) (local.get $yp1)
          (call $pack_rgba (local.get $r) (local.get $g) (local.get $b) (local.get $a1)))
        (call $fb_blend (local.get $xp1) (i32.add (local.get $yp1) (i32.const 1))
          (call $pack_rgba (local.get $r) (local.get $g) (local.get $b) (local.get $a2)))))
    (local.set $intery (f64.add (local.get $yend) (local.get $grad)))
    ;; second endpoint
    (local.set $xend (f64.nearest (local.get $fx1)))
    (local.set $yend (f64.add (local.get $fy1)
      (f64.mul (local.get $grad) (f64.sub (local.get $xend) (local.get $fx1)))))
    (local.set $ygap (f64.sub
      (f64.add (local.get $fx1) (f64.const 0.5))
      (f64.floor (f64.add (local.get $fx1) (f64.const 0.5)))))
    (local.set $xp2 (i32.trunc_sat_f64_s (local.get $xend)))
    (local.set $yp2 (i32.trunc_sat_f64_s (f64.floor (local.get $yend))))
    (local.set $frac (f64.sub (local.get $yend) (f64.floor (local.get $yend))))
    (local.set $a1 (i32.trunc_sat_f64_s
      (f64.mul (f64.sub (f64.const 1.0) (local.get $frac))
               (f64.mul (local.get $ygap) (f64.const 255.0)))))
    (local.set $a2 (i32.trunc_sat_f64_s
      (f64.mul (local.get $frac) (f64.mul (local.get $ygap) (f64.const 255.0)))))
    (if (local.get $steep)
      (then
        (call $fb_blend (local.get $yp2) (local.get $xp2)
          (call $pack_rgba (local.get $r) (local.get $g) (local.get $b) (local.get $a1)))
        (call $fb_blend (i32.add (local.get $yp2) (i32.const 1)) (local.get $xp2)
          (call $pack_rgba (local.get $r) (local.get $g) (local.get $b) (local.get $a2))))
      (else
        (call $fb_blend (local.get $xp2) (local.get $yp2)
          (call $pack_rgba (local.get $r) (local.get $g) (local.get $b) (local.get $a1)))
        (call $fb_blend (local.get $xp2) (i32.add (local.get $yp2) (i32.const 1))
          (call $pack_rgba (local.get $r) (local.get $g) (local.get $b) (local.get $a2)))))
    ;; main loop
    (local.set $ix (i32.add (local.get $xp1) (i32.const 1)))
    (block $brk (loop $lp
      (br_if $brk (i32.ge_s (local.get $ix) (local.get $xp2)))
      (local.set $frac (f64.sub (local.get $intery) (f64.floor (local.get $intery))))
      (local.set $a1 (i32.trunc_sat_f64_s
        (f64.mul (f64.sub (f64.const 1.0) (local.get $frac)) (f64.const 255.0))))
      (local.set $a2 (i32.trunc_sat_f64_s
        (f64.mul (local.get $frac) (f64.const 255.0))))
      (local.set $yp1 (i32.trunc_sat_f64_s (f64.floor (local.get $intery))))
      (if (local.get $steep)
        (then
          (call $fb_blend (local.get $yp1) (local.get $ix)
            (call $pack_rgba (local.get $r) (local.get $g) (local.get $b) (local.get $a1)))
          (call $fb_blend (i32.add (local.get $yp1) (i32.const 1)) (local.get $ix)
            (call $pack_rgba (local.get $r) (local.get $g) (local.get $b) (local.get $a2))))
        (else
          (call $fb_blend (local.get $ix) (local.get $yp1)
            (call $pack_rgba (local.get $r) (local.get $g) (local.get $b) (local.get $a1)))
          (call $fb_blend (local.get $ix) (i32.add (local.get $yp1) (i32.const 1))
            (call $pack_rgba (local.get $r) (local.get $g) (local.get $b) (local.get $a2)))))
      (local.set $intery (f64.add (local.get $intery) (local.get $grad)))
      (local.set $ix (i32.add (local.get $ix) (i32.const 1)))
      (br $lp))))

  ;; Fill the vertical strip between the line and base_y (area chart fill)
  (func $fill_trapezoid
    (param $x0 i32) (param $y0 i32) (param $x1 i32) (param $y1 i32)
    (param $base_y i32) (param $col i32)
    (local $x i32) (local $dx i32) (local $iy f64) (local $iyi i32)
    (if (i32.eq (local.get $x0) (local.get $x1)) (then (return)))
    (if (i32.gt_s (local.get $x0) (local.get $x1))
      (then
        (local.set $x (local.get $x0)) (local.set $x0 (local.get $x1)) (local.set $x1 (local.get $x))
        (local.set $x (local.get $y0)) (local.set $y0 (local.get $y1)) (local.set $y1 (local.get $x))))
    (local.set $dx (i32.sub (local.get $x1) (local.get $x0)))
    (local.set $x (local.get $x0))
    (block $brk (loop $lp
      (br_if $brk (i32.gt_s (local.get $x) (local.get $x1)))
      (local.set $iy
        (f64.add (f64.convert_i32_s (local.get $y0))
          (f64.mul
            (f64.div (f64.convert_i32_s (i32.sub (local.get $x) (local.get $x0)))
                     (f64.convert_i32_s (local.get $dx)))
            (f64.convert_i32_s (i32.sub (local.get $y1) (local.get $y0))))))
      (local.set $iyi (i32.trunc_sat_f64_s (local.get $iy)))
      (call $draw_vline (local.get $x) (local.get $iyi) (local.get $base_y) (local.get $col))
      (local.set $x (i32.add (local.get $x) (i32.const 1)))
      (br $lp))))

  ;; ── coordinate transforms ─────────────────────────────────────────────
  (func $time_to_x (param $ts i64) (result i32)
    (local $range i64) (local $off i64)
    (local.set $range (i64.sub (call $view_e) (call $view_s)))
    (if (i64.le_s (local.get $range) (i64.const 0)) (then (return (call $cx))))
    (local.set $off (i64.sub (local.get $ts) (call $view_s)))
    (i32.add (call $cx)
      (i32.trunc_sat_f64_s
        (f64.div
          (f64.mul (f64.convert_i64_s (local.get $off))
                   (f64.convert_i32_s (call $caw)))
          (f64.convert_i64_s (local.get $range))))))

  (func $price_to_y (param $price f64) (result i32)
    (local $range f64)
    (local.set $range (f64.sub (call $pmax) (call $pmin)))
    (if (f64.le (local.get $range) (f64.const 0))
      (then (return (i32.add (call $cy) (i32.shr_s (call $cah) (i32.const 1))))))
    (i32.add (call $cy)
      (i32.trunc_sat_f64_s
        (f64.mul
          (f64.sub (f64.const 1.0)
            (f64.div (f64.sub (local.get $price) (call $pmin)) (local.get $range)))
          (f64.convert_i32_s (call $cah))))))

  (func $x_to_time (param $x i32) (result i64)
    (local $range i64)
    (local.set $range (i64.sub (call $view_e) (call $view_s)))
    (i64.add (call $view_s)
      (i64.trunc_sat_f64_s
        (f64.div
          (f64.mul (f64.convert_i32_s (i32.sub (local.get $x) (call $cx)))
                   (f64.convert_i64_s (local.get $range)))
          (f64.convert_i32_s (call $caw))))))

  (func $y_to_price (param $y i32) (result f64)
    (local $range f64)
    (local.set $range (f64.sub (call $pmax) (call $pmin)))
    (f64.add (call $pmin)
      (f64.mul
        (f64.sub (f64.const 1.0)
          (f64.div (f64.convert_i32_s (i32.sub (local.get $y) (call $cy)))
                   (f64.convert_i32_s (call $cah))))
        (local.get $range))))

  ;; ── dataset registry helpers ──────────────────────────────────────────
  ;; Pointer to start of registry entry for ds_id
  (func $ds_ptr (param $id i32) (result i32)
    (i32.add (i32.const 0x100) (i32.shl (local.get $id) (i32.const 8))))

  (func $ds_type_of  (param $id i32) (result i32) (i32.load offset=4  (call $ds_ptr (local.get $id))))
  (func $ds_recsz    (param $id i32) (result i32) (i32.load offset=8  (call $ds_ptr (local.get $id))))
  (func $ds_cnt      (param $id i32) (result i32) (i32.load offset=12 (call $ds_ptr (local.get $id))))
  (func $ds_ts_start (param $id i32) (result i64) (i64.load offset=16 (call $ds_ptr (local.get $id))))
  (func $ds_ts_end   (param $id i32) (result i64) (i64.load offset=24 (call $ds_ptr (local.get $id))))
  (func $ds_data_ptr (param $id i32) (result i32) (i32.load offset=32 (call $ds_ptr (local.get $id))))

  (func $ds_rec_ptr (param $id i32) (param $idx i32) (result i32)
    (i32.add (call $ds_data_ptr (local.get $id))
             (i32.mul (local.get $idx) (call $ds_recsz (local.get $id)))))

  ;; Binary search: first index where ts >= target (lo=0, hi=count)
  (func $ds_lower_bound (param $id i32) (param $target i64) (result i32)
    (local $lo i32) (local $hi i32) (local $mid i32)
    (local.set $lo (i32.const 0))
    (local.set $hi (call $ds_cnt (local.get $id)))
    (block $done (loop $bisect
      (br_if $done (i32.ge_u (local.get $lo) (local.get $hi)))
      (local.set $mid (i32.shr_u (i32.add (local.get $lo) (local.get $hi)) (i32.const 1)))
      (if (i64.lt_s (i64.load (call $ds_rec_ptr (local.get $id) (local.get $mid)))
                    (local.get $target))
        (then (local.set $lo (i32.add (local.get $mid) (i32.const 1))))
        (else (local.set $hi (local.get $mid))))
      (br $bisect)))
    (local.get $lo))

  ;; Binary search: last index where ts <= target (returns -1 if none)
  (func $ds_upper_bound (param $id i32) (param $target i64) (result i32)
    (local $lo i32) (local $hi i32) (local $mid i32)
    (local.set $lo (i32.const 0))
    (local.set $hi (call $ds_cnt (local.get $id)))
    (block $done (loop $bisect
      (br_if $done (i32.ge_u (local.get $lo) (local.get $hi)))
      (local.set $mid (i32.shr_u (i32.add (local.get $lo) (local.get $hi)) (i32.const 1)))
      (if (i64.le_s (i64.load (call $ds_rec_ptr (local.get $id) (local.get $mid)))
                    (local.get $target))
        (then (local.set $lo (i32.add (local.get $mid) (i32.const 1))))
        (else (local.set $hi (local.get $mid))))
      (br $bisect)))
    (i32.sub (local.get $lo) (i32.const 1)))

  ;; ── indicator registry helpers ────────────────────────────────────────
  (func $ind_ptr (param $id i32) (result i32)
    (i32.add (i32.const 0x2100) (i32.shl (local.get $id) (i32.const 8))))

  ;; ── PUBLIC API ────────────────────────────────────────────────────────

  (func (export "init") (param $width i32) (param $height i32)
    ;; canvas size
    (i32.store offset=0  (i32.const 0) (local.get $width))
    (i32.store offset=4  (i32.const 0) (local.get $height))
    ;; default margins
    (i32.store offset=112 (i32.const 0) (i32.const 60))
    (i32.store offset=116 (i32.const 0) (i32.const 20))
    (i32.store offset=120 (i32.const 0) (i32.const 80))
    (i32.store offset=124 (i32.const 0) (i32.const 40))
    ;; default theme — TradingView dark
    (i32.store offset=64  (i32.const 0) (call $pack_rgba (i32.const 26)  (i32.const 26)  (i32.const 46)  (i32.const 255)))
    (i32.store offset=68  (i32.const 0) (call $pack_rgba (i32.const 64)  (i32.const 64)  (i32.const 80)  (i32.const 128)))
    (i32.store offset=72  (i32.const 0) (call $pack_rgba (i32.const 38)  (i32.const 166) (i32.const 154) (i32.const 255)))
    (i32.store offset=76  (i32.const 0) (call $pack_rgba (i32.const 239) (i32.const 83)  (i32.const 80)  (i32.const 255)))
    (i32.store offset=80  (i32.const 0) (call $pack_rgba (i32.const 33)  (i32.const 150) (i32.const 243) (i32.const 255)))
    (i32.store offset=84  (i32.const 0) (call $pack_rgba (i32.const 200) (i32.const 200) (i32.const 220) (i32.const 255)))
    ;; default active ds, chart type
    (i32.store offset=24 (i32.const 0) (i32.const -1))
    (i32.store offset=28 (i32.const 0) (i32.const 0))
    ;; volume panel
    (i32.store offset=136 (i32.const 0) (i32.const 1))
    (i32.store offset=140 (i32.const 0) (i32.const 80))
    ;; indicator sub-panel (off by default)
    (i32.store offset=144 (i32.const 0) (i32.const 0))
    (i32.store offset=148 (i32.const 0) (i32.const 70))
    (f64.store offset=152 (i32.const 0) (f64.const 0))
    (f64.store offset=160 (i32.const 0) (f64.const 100))
    ;; crosshair off
    (i32.store offset=128 (i32.const 0) (i32.const -1))
    (i32.store offset=132 (i32.const 0) (i32.const -1))
    ;; initialise 3×5 pixel font data
    (call $init_font)
    ;; recalculate chart area
    (call $recalc_chart_area))

  (func (export "set_canvas_size") (param $width i32) (param $height i32)
    (i32.store offset=0 (i32.const 0) (local.get $width))
    (i32.store offset=4 (i32.const 0) (local.get $height))
    (call $recalc_chart_area))

  (func (export "get_fb_ptr") (result i32) (i32.const 0x010000))

  (func (export "get_fb_size") (result i32)
    (i32.shl (i32.mul (call $cw) (call $ch)) (i32.const 2)))

  (func (export "set_theme")
    (param $bg i32) (param $grid i32) (param $text i32)
    (param $up i32) (param $down i32) (param $line i32)
    (i32.store offset=64 (i32.const 0) (local.get $bg))
    (i32.store offset=68 (i32.const 0) (local.get $grid))
    (i32.store offset=72 (i32.const 0) (local.get $up))
    (i32.store offset=76 (i32.const 0) (local.get $down))
    (i32.store offset=80 (i32.const 0) (local.get $line))
    (i32.store offset=84 (i32.const 0) (local.get $text)))

  (func (export "set_margins")
    (param $left i32) (param $top i32) (param $right i32) (param $bottom i32)
    (i32.store offset=112 (i32.const 0) (local.get $left))
    (i32.store offset=116 (i32.const 0) (local.get $top))
    (i32.store offset=120 (i32.const 0) (local.get $right))
    (i32.store offset=124 (i32.const 0) (local.get $bottom))
    (call $recalc_chart_area))

  (func (export "set_show_volume") (param $show i32) (param $panel_h i32)
    (i32.store offset=136 (i32.const 0) (local.get $show))
    (i32.store offset=140 (i32.const 0) (local.get $panel_h))
    (call $recalc_chart_area))

  ;; Configure the indicator sub-panel (RSI / MACD panel below main chart)
  (func (export "set_ind_panel") (param $show i32) (param $h i32)
    (i32.store offset=144 (i32.const 0) (local.get $show))
    (i32.store offset=148 (i32.const 0) (local.get $h))
    (call $recalc_chart_area))

  ;; Auto-scale the indicator panel range from all RSI/MACD indicator values
  (func (export "auto_scale_ind_panel")
    (local $n i32) (local $i i32) (local $ip i32) (local $type i32)
    (local $dp i32) (local $cnt i32) (local $j i32) (local $v f64)
    (local $mn f64) (local $mx f64)
    (local.set $mn (f64.const 1e15))
    (local.set $mx (f64.const -1e15))
    (local.set $n (call $ind_count))
    (local.set $i (i32.const 0))
    (block $brk (loop $lp
      (br_if $brk (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $ip   (call $ind_ptr (local.get $i)))
      (local.set $type (i32.load offset=4  (local.get $ip)))
      (if (i32.and (i32.load offset=60 (local.get $ip))
                   (i32.or (i32.eq (local.get $type) (i32.const 5))
                           (i32.eq (local.get $type) (i32.const 6))))
        (then
          (local.set $dp  (i32.load offset=48 (local.get $ip)))
          (local.set $cnt (i32.load offset=52 (local.get $ip)))
          (local.set $j (i32.const 0))
          (block $ib (loop $il
            (br_if $ib (i32.ge_s (local.get $j) (local.get $cnt)))
            (local.set $v (f64.load (i32.add (local.get $dp) (i32.shl (local.get $j) (i32.const 3)))))
            (if (f64.ne (local.get $v) (f64.const 0))
              (then
                (if (f64.lt (local.get $v) (local.get $mn)) (then (local.set $mn (local.get $v))))
                (if (f64.gt (local.get $v) (local.get $mx)) (then (local.set $mx (local.get $v))))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $il)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    ;; clamp for RSI (0-100 range); for MACD use symmetric range
    (if (f64.lt (local.get $mn) (f64.const 1e14))
      (then
        (local.set $mn (f64.sub (local.get $mn) (f64.mul (f64.sub (local.get $mx) (local.get $mn)) (f64.const 0.05))))
        (local.set $mx (f64.add (local.get $mx) (f64.mul (f64.sub (local.get $mx) (local.get $mn)) (f64.const 0.05))))
        (f64.store offset=152 (i32.const 0) (local.get $mn))
        (f64.store offset=160 (i32.const 0) (local.get $mx)))))

  (func (export "set_active_ds") (param $id i32)
    (i32.store offset=24 (i32.const 0) (local.get $id)))

  (func (export "set_chart_type") (param $type i32)
    (i32.store offset=28 (i32.const 0) (local.get $type)))

  (func (export "set_view_range") (param $start i64) (param $end i64)
    (i64.store offset=32 (i32.const 0) (local.get $start))
    (i64.store offset=40 (i32.const 0) (local.get $end)))

  (func (export "set_price_range") (param $pmin f64) (param $pmax f64)
    (f64.store offset=48 (i32.const 0) (local.get $pmin))
    (f64.store offset=56 (i32.const 0) (local.get $pmax)))

  (func (export "set_crosshair") (param $x i32) (param $y i32)
    (i32.store offset=128 (i32.const 0) (local.get $x))
    (i32.store offset=132 (i32.const 0) (local.get $y)))

  (func (export "get_ds_count") (result i32) (call $ds_count))

  (func (export "get_ds_record_count") (param $id i32) (result i32)
    (call $ds_cnt (local.get $id)))

  (func (export "get_ds_time_start") (param $id i32) (result i64)
    (call $ds_ts_start (local.get $id)))

  (func (export "get_ds_time_end") (param $id i32) (result i64)
    (call $ds_ts_end (local.get $id)))

  (func (export "x_to_time_export") (param $x i32) (result i64)
    (call $x_to_time (local.get $x)))

  (func (export "y_to_price_export") (param $y i32) (result f64)
    (call $y_to_price (local.get $y)))

  ;; ── auto-scale ────────────────────────────────────────────────────────
  (func (export "auto_scale_price")
    (local $id i32) (local $n i32) (local $s i32) (local $e i32)
    (local $i i32) (local $p i32) (local $lo f64) (local $hi f64)
    (local $mn f64) (local $mx f64) (local $pad f64)
    (local.set $id (call $active_ds))
    (if (i32.lt_s (local.get $id) (i32.const 0)) (then (return)))
    (local.set $n (call $ds_cnt (local.get $id)))
    (if (i32.eqz (local.get $n)) (then (return)))
    (local.set $s (call $ds_lower_bound (local.get $id) (call $view_s)))
    (local.set $e (call $ds_upper_bound (local.get $id) (call $view_e)))
    (if (i32.gt_s (local.get $s) (local.get $e)) (then (return)))
    (local.set $mn (f64.const 1e15))
    (local.set $mx (f64.const -1e15))
    (local.set $i (local.get $s))
    (block $brk (loop $lp
      (br_if $brk (i32.gt_s (local.get $i) (local.get $e)))
      (local.set $p (call $ds_rec_ptr (local.get $id) (local.get $i)))
      (if (i32.eqz (call $ds_type_of (local.get $id)))
        (then
          (local.set $lo (f64.load offset=24 (local.get $p)))
          (local.set $hi (f64.load offset=16 (local.get $p))))
        (else
          (local.set $lo (f64.load offset=8 (local.get $p)))
          (local.set $hi (local.get $lo))))
      (if (f64.lt (local.get $lo) (local.get $mn)) (then (local.set $mn (local.get $lo))))
      (if (f64.gt (local.get $hi) (local.get $mx)) (then (local.set $mx (local.get $hi))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (local.set $pad (f64.mul (f64.sub (local.get $mx) (local.get $mn)) (f64.const 0.05)))
    (f64.store offset=48 (i32.const 0) (f64.sub (local.get $mn) (local.get $pad)))
    (f64.store offset=56 (i32.const 0) (f64.add (local.get $mx) (local.get $pad))))

  ;; ── clear ─────────────────────────────────────────────────────────────
  (func (export "clear")
    (local $ptr i32) (local $end i32) (local $col i32)
    (local.set $col (call $bg_col))
    (local.set $ptr (i32.const 0x010000))
    (local.set $end (i32.add (local.get $ptr)
      (i32.shl (i32.mul (call $cw) (call $ch)) (i32.const 2))))
    (block $brk (loop $lp
      (br_if $brk (i32.ge_u (local.get $ptr) (local.get $end)))
      (i32.store (local.get $ptr) (local.get $col))
      (local.set $ptr (i32.add (local.get $ptr) (i32.const 4)))
      (br $lp))))

  ;; ── dataset write API ─────────────────────────────────────────────────
  (func $begin_dataset (export "begin_dataset") (param $type i32) (result i32)
    (local $id i32) (local $rp i32)
    (local.set $id (call $ds_count))
    (if (i32.ge_s (local.get $id) (i32.const 32)) (then (return (i32.const -1))))
    (i32.store offset=96  (i32.const 0) (local.get $id))
    (i32.store offset=100 (i32.const 0) (global.get $g_stor_cur))
    (i64.store offset=104 (i32.const 0) (i64.const 0))
    (local.set $rp (call $ds_ptr (local.get $id)))
    (i32.store offset=0  (local.get $rp) (local.get $id))
    (i32.store offset=4  (local.get $rp) (local.get $type))
    (i32.store offset=8  (local.get $rp)
      (select (i32.const 48) (i32.const 16) (i32.eqz (local.get $type))))
    (i32.store offset=12 (local.get $rp) (i32.const 0))
    (i64.store offset=16 (local.get $rp) (i64.const 0x7FFFFFFFFFFFFFFF))
    (i64.store offset=24 (local.get $rp) (i64.const -9223372036854775808))
    (i32.store offset=32 (local.get $rp) (global.get $g_stor_cur))
    (local.get $id))

  (func (export "write_ohlcv")
    (param $ts i64) (param $open f64) (param $high f64)
    (param $low f64) (param $close f64) (param $vol f64)
    (local $ptr i32) (local $rp i32)
    (local.set $ptr (i32.load offset=100 (i32.const 0)))
    (local.set $rp  (call $ds_ptr (i32.load offset=96 (i32.const 0))))
    (i64.store offset=0  (local.get $ptr) (local.get $ts))
    (f64.store offset=8  (local.get $ptr) (local.get $open))
    (f64.store offset=16 (local.get $ptr) (local.get $high))
    (f64.store offset=24 (local.get $ptr) (local.get $low))
    (f64.store offset=32 (local.get $ptr) (local.get $close))
    (f64.store offset=40 (local.get $ptr) (local.get $vol))
    (i32.store offset=100 (i32.const 0) (i32.add (local.get $ptr) (i32.const 48)))
    (i32.store offset=12 (local.get $rp)
      (i32.add (i32.load offset=12 (local.get $rp)) (i32.const 1)))
    (if (i64.lt_s (local.get $ts) (i64.load offset=16 (local.get $rp)))
      (then (i64.store offset=16 (local.get $rp) (local.get $ts))))
    (if (i64.gt_s (local.get $ts) (i64.load offset=24 (local.get $rp)))
      (then (i64.store offset=24 (local.get $rp) (local.get $ts)))))

  (func (export "write_tv") (param $ts i64) (param $val f64)
    (local $ptr i32) (local $rp i32)
    (local.set $ptr (i32.load offset=100 (i32.const 0)))
    (local.set $rp  (call $ds_ptr (i32.load offset=96 (i32.const 0))))
    (i64.store offset=0 (local.get $ptr) (local.get $ts))
    (f64.store offset=8 (local.get $ptr) (local.get $val))
    (i32.store offset=100 (i32.const 0) (i32.add (local.get $ptr) (i32.const 16)))
    (i32.store offset=12 (local.get $rp)
      (i32.add (i32.load offset=12 (local.get $rp)) (i32.const 1)))
    (if (i64.lt_s (local.get $ts) (i64.load offset=16 (local.get $rp)))
      (then (i64.store offset=16 (local.get $rp) (local.get $ts))))
    (if (i64.gt_s (local.get $ts) (i64.load offset=24 (local.get $rp)))
      (then (i64.store offset=24 (local.get $rp) (local.get $ts)))))

  (func (export "end_dataset")
    (global.set $g_stor_cur (i32.load offset=100 (i32.const 0)))
    (i32.store offset=88 (i32.const 0)
      (i32.add (call $ds_count) (i32.const 1))))

  ;; Load binary .bin data from TypeScript-supplied buffer (from OPFS)
  (func (export "load_bin") (param $src i32) (param $len i32) (result i32)
    (local $id i32) (local $type i32) (local $cnt i64)
    (local $rsz i32) (local $dsz i32) (local $rp i32) (local $dst i32)
    (local $required i32)
    (if (i32.lt_s (local.get $len) (i32.const 72)) (then (return (i32.const -1))))
    ;; check magic "ATLC" (0x434C5441)
    (if (i32.ne (i32.load (local.get $src)) (i32.const 0x434C5441))
      (then (return (i32.const -1))))
    ;; check version "DB10" (0x30314244)
    (if (i32.ne (i32.load offset=4 (local.get $src)) (i32.const 0x30314244))
      (then (return (i32.const -1))))
    (local.set $type (i32.load offset=8  (local.get $src)))
    ;; type must be 0 (OHLCV) or 1 (TimeValue)
    (if (i32.gt_u (local.get $type) (i32.const 1)) (then (return (i32.const -1))))
    (local.set $cnt  (i64.load offset=12 (local.get $src)))
    ;; cnt must be non-negative and fit in a reasonable bound (≤ 1 million records)
    (if (i32.or (i64.lt_s (local.get $cnt) (i64.const 0))
                (i64.gt_s (local.get $cnt) (i64.const 1000000)))
      (then (return (i32.const -1))))
    (local.set $rsz (select (i32.const 48) (i32.const 16) (i32.eqz (local.get $type))))
    (local.set $dsz (i32.mul (i32.wrap_i64 (local.get $cnt)) (local.get $rsz)))
    ;; verify buffer length covers header + records
    (local.set $required (i32.add (i32.const 72) (local.get $dsz)))
    (if (i32.lt_s (local.get $len) (local.get $required)) (then (return (i32.const -1))))
    (local.set $id (call $begin_dataset (local.get $type)))
    (if (i32.lt_s (local.get $id) (i32.const 0)) (then (return (i32.const -1))))
    (local.set $dst (global.get $g_stor_cur))
    (memory.copy (local.get $dst)
                 (i32.add (local.get $src) (i32.const 72))
                 (local.get $dsz))
    (local.set $rp (call $ds_ptr (local.get $id)))
    (i32.store offset=12 (local.get $rp) (i32.wrap_i64 (local.get $cnt)))
    (i64.store offset=16 (local.get $rp) (i64.load offset=20 (local.get $src)))
    (i64.store offset=24 (local.get $rp) (i64.load offset=28 (local.get $src)))
    (global.set $g_stor_cur (i32.add (local.get $dst) (local.get $dsz)))
    (i32.store offset=88 (i32.const 0)
      (i32.add (call $ds_count) (i32.const 1)))
    (local.get $id))

  ;; Serialize dataset to binary .bin format; returns bytes written
  (func (export "serialize_dataset") (param $id i32) (param $out i32) (result i32)
    (local $rp i32) (local $type i32) (local $cnt i32) (local $rsz i32) (local $dsz i32)
    (if (i32.ge_s (local.get $id) (call $ds_count)) (then (return (i32.const -1))))
    (local.set $rp   (call $ds_ptr (local.get $id)))
    (local.set $type (i32.load offset=4  (local.get $rp)))
    (local.set $cnt  (i32.load offset=12 (local.get $rp)))
    (local.set $rsz  (i32.load offset=8  (local.get $rp)))
    (local.set $dsz  (i32.mul (local.get $cnt) (local.get $rsz)))
    (i32.store offset=0 (local.get $out) (i32.const 0x434C5441))
    (i32.store offset=4 (local.get $out) (i32.const 0x30314244))
    (i32.store offset=8 (local.get $out) (local.get $type))
    (i64.store offset=12 (local.get $out) (i64.extend_i32_s (local.get $cnt)))
    (i64.store offset=20 (local.get $out) (i64.load offset=16 (local.get $rp)))
    (i64.store offset=28 (local.get $out) (i64.load offset=24 (local.get $rp)))
    (memory.fill (i32.add (local.get $out) (i32.const 36)) (i32.const 0) (i32.const 36))
    (memory.copy (i32.add (local.get $out) (i32.const 72))
                 (i32.load offset=32 (local.get $rp))
                 (local.get $dsz))
    (i32.add (i32.const 72) (local.get $dsz)))

  ;; get_ohlcv_at: copy 48-byte OHLCV record to out_ptr, return 48 (or -1)
  (func (export "get_ohlcv_at") (param $id i32) (param $idx i32) (param $out i32) (result i32)
    (if (i32.ge_s (local.get $idx) (call $ds_cnt (local.get $id)))
      (then (return (i32.const -1))))
    (memory.copy (local.get $out) (call $ds_rec_ptr (local.get $id) (local.get $idx)) (i32.const 48))
    (i32.const 48))

  ;; ── indicator API ─────────────────────────────────────────────────────
  (func (export "add_indicator")
    (param $type i32) (param $dsid i32) (param $period i32) (param $color i32)
    (param $p1 f64) (param $p2 f64) (param $p3 f64)
    (result i32)
    (local $id i32) (local $ip i32)
    (local.set $id (call $ind_count))
    (if (i32.ge_s (local.get $id) (i32.const 16)) (then (return (i32.const -1))))
    (local.set $ip (call $ind_ptr (local.get $id)))
    (i32.store offset=0  (local.get $ip) (local.get $id))
    (i32.store offset=4  (local.get $ip) (local.get $type))
    (i32.store offset=8  (local.get $ip) (local.get $dsid))
    (i32.store offset=12 (local.get $ip) (local.get $period))
    (i32.store offset=16 (local.get $ip) (local.get $color))
    (i32.store offset=20 (local.get $ip) (i32.const 1))
    (f64.store offset=24 (local.get $ip) (local.get $p1))
    (f64.store offset=32 (local.get $ip) (local.get $p2))
    (f64.store offset=40 (local.get $ip) (local.get $p3))
    (i32.store offset=48 (local.get $ip) (i32.const 0))
    (i32.store offset=52 (local.get $ip) (i32.const 0))
    (i32.store offset=60 (local.get $ip) (i32.const 1))
    (i32.store offset=92 (i32.const 0)
      (i32.add (call $ind_count) (i32.const 1)))
    (local.get $id))

  (func (export "remove_indicator") (param $id i32)
    (i32.store offset=60 (call $ind_ptr (local.get $id)) (i32.const 0)))

  ;; Scratch area: 0x3100 (~53KB).  Use as temp f64 array for ind computations
  ;; $compute_indicators allocates ind value arrays from $g_stor_cur
  (func (export "compute_indicators")
    (local $n i32) (local $i i32) (local $ip i32) (local $type i32) (local $dsid i32)
    (local $period i32) (local $cnt i32) (local $out i32) (local $sz i32) (local $enabled i32)
    (local.set $n (call $ind_count))
    (local.set $i (i32.const 0))
    (block $brk (loop $lp
      (br_if $brk (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $ip      (call $ind_ptr (local.get $i)))
      (local.set $enabled (i32.load offset=60 (local.get $ip)))
      (if (local.get $enabled)
        (then
          (local.set $type   (i32.load offset=4  (local.get $ip)))
          (local.set $dsid   (i32.load offset=8  (local.get $ip)))
          (local.set $period (i32.load offset=12 (local.get $ip)))
          (local.set $cnt    (call $ds_cnt (local.get $dsid)))
          ;; BB and MACD need 3 output arrays (mid/upper/lower or line/signal/hist)
          (local.set $sz (i32.shl (local.get $cnt) (i32.const 3)))  ;; cnt * 8
          (local.set $sz (select
            (i32.mul (local.get $sz) (i32.const 3))
            (local.get $sz)
            (i32.or (i32.eq (local.get $type) (i32.const 2))
                    (i32.eq (local.get $type) (i32.const 6)))))
          (local.set $out (global.get $g_stor_cur))
          (i32.store offset=48 (local.get $ip) (local.get $out))
          (i32.store offset=52 (local.get $ip) (local.get $cnt))
          (global.set $g_stor_cur (i32.add (local.get $out) (local.get $sz)))
          ;; dispatch
          (if (i32.eqz (local.get $type))
            (then (call $compute_sma (local.get $dsid) (local.get $period) (local.get $out) (local.get $cnt))))
          (if (i32.eq (local.get $type) (i32.const 1))
            (then (call $compute_ema (local.get $dsid) (local.get $period) (local.get $out) (local.get $cnt))))
          (if (i32.eq (local.get $type) (i32.const 2))
            (then
              (call $compute_bb (local.get $ip) (local.get $dsid) (local.get $period)
                                (local.get $out) (local.get $cnt))))
          (if (i32.eq (local.get $type) (i32.const 5))
            (then (call $compute_rsi (local.get $dsid) (local.get $period) (local.get $out) (local.get $cnt))))
          (if (i32.eq (local.get $type) (i32.const 6))
            (then (call $compute_macd (local.get $ip) (local.get $dsid) (local.get $out) (local.get $cnt)))))
        (else
          ;; disabled: clear output pointers so the renderer skips it
          (i32.store offset=48 (local.get $ip) (i32.const 0))
          (i32.store offset=52 (local.get $ip) (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; helper: get close/value at index i for any dataset type
  (func $ds_val (param $id i32) (param $i i32) (result f64)
    (local $p i32)
    (local.set $p (call $ds_rec_ptr (local.get $id) (local.get $i)))
    (select
      (f64.load offset=32 (local.get $p))
      (f64.load offset=8  (local.get $p))
      (i32.eqz (call $ds_type_of (local.get $id)))))

  ;; ── SMA ──────────────────────────────────────────────────────────────
  (func $compute_sma
    (param $id i32) (param $period i32) (param $out i32) (param $cnt i32)
    (local $i i32) (local $j i32) (local $sum f64) (local $start i32)
    (local.set $i (i32.const 0))
    (block $brk (loop $lp
      (br_if $brk (i32.ge_s (local.get $i) (local.get $cnt)))
      (local.set $start (i32.sub (local.get $i) (i32.sub (local.get $period) (i32.const 1))))
      (if (i32.lt_s (local.get $start) (i32.const 0))
        (then
          (f64.store (i32.add (local.get $out) (i32.shl (local.get $i) (i32.const 3))) (f64.const 0))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $lp))
        (else
          (local.set $sum (f64.const 0))
          (local.set $j (local.get $start))
          (block $ib (loop $il
            (br_if $ib (i32.gt_s (local.get $j) (local.get $i)))
            (local.set $sum (f64.add (local.get $sum) (call $ds_val (local.get $id) (local.get $j))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $il)))
          (f64.store
            (i32.add (local.get $out) (i32.shl (local.get $i) (i32.const 3)))
            (f64.div (local.get $sum) (f64.convert_i32_s (local.get $period))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; ── EMA ──────────────────────────────────────────────────────────────
  (func $compute_ema
    (param $id i32) (param $period i32) (param $out i32) (param $cnt i32)
    (local $i i32) (local $k f64) (local $prev f64) (local $cur f64) (local $v f64)
    (local.set $k (f64.div (f64.const 2.0)
      (f64.add (f64.convert_i32_s (local.get $period)) (f64.const 1.0))))
    (local.set $i (i32.const 0))
    (local.set $prev (f64.const 0))
    (block $brk (loop $lp
      (br_if $brk (i32.ge_s (local.get $i) (local.get $cnt)))
      (local.set $v (call $ds_val (local.get $id) (local.get $i)))
      (if (i32.lt_s (local.get $i) (local.get $period))
        (then
          ;; seed: accumulate simple average for first 'period' bars
          (local.set $prev (f64.add (local.get $prev) (local.get $v)))
          (if (i32.eq (local.get $i) (i32.sub (local.get $period) (i32.const 1)))
            (then (local.set $prev (f64.div (local.get $prev)
                    (f64.convert_i32_s (local.get $period))))))
          (f64.store
            (i32.add (local.get $out) (i32.shl (local.get $i) (i32.const 3)))
            (f64.const 0)))
        (else
          (local.set $cur
            (f64.add (f64.mul (local.get $v) (local.get $k))
                     (f64.mul (local.get $prev)
                              (f64.sub (f64.const 1.0) (local.get $k)))))
          (f64.store
            (i32.add (local.get $out) (i32.shl (local.get $i) (i32.const 3)))
            (local.get $cur))
          (local.set $prev (local.get $cur))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; ── Bollinger Bands ───────────────────────────────────────────────────
  ;; Stores: mid at out[i], upper & lower at (out + cnt*8)[i] and (out + cnt*16)[i]
  ;; (TypeScript knows the layout via ind.data_ptr + count*8*offset)
  (func $compute_bb
    (param $ip i32) (param $id i32) (param $period i32) (param $out i32) (param $cnt i32)
    (local $i i32) (local $j i32) (local $sum f64) (local $sum2 f64)
    (local $mean f64) (local $variance f64) (local $sd f64)
    (local $mult f64) (local $start i32) (local $v f64)
    (local.set $mult (f64.load offset=24 (local.get $ip)))
    (if (f64.eq (local.get $mult) (f64.const 0)) (then (local.set $mult (f64.const 2.0))))
    (local.set $i (i32.const 0))
    (block $brk (loop $lp
      (br_if $brk (i32.ge_s (local.get $i) (local.get $cnt)))
      (local.set $start (i32.sub (local.get $i) (i32.sub (local.get $period) (i32.const 1))))
      (if (i32.lt_s (local.get $start) (i32.const 0))
        (then
          (f64.store (i32.add (local.get $out) (i32.shl (local.get $i) (i32.const 3))) (f64.const 0))
          (f64.store (i32.add (i32.add (local.get $out) (i32.shl (local.get $cnt) (i32.const 3)))
                      (i32.shl (local.get $i) (i32.const 3))) (f64.const 0))
          (f64.store (i32.add (i32.add (local.get $out) (i32.shl (i32.mul (local.get $cnt) (i32.const 2)) (i32.const 3)))
                      (i32.shl (local.get $i) (i32.const 3))) (f64.const 0)))
        (else
          (local.set $sum (f64.const 0))
          (local.set $sum2 (f64.const 0))
          (local.set $j (local.get $start))
          (block $ib (loop $il
            (br_if $ib (i32.gt_s (local.get $j) (local.get $i)))
            (local.set $v (call $ds_val (local.get $id) (local.get $j)))
            (local.set $sum (f64.add (local.get $sum) (local.get $v)))
            (local.set $sum2 (f64.add (local.get $sum2) (f64.mul (local.get $v) (local.get $v))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $il)))
          (local.set $mean (f64.div (local.get $sum) (f64.convert_i32_s (local.get $period))))
          (local.set $variance
            (f64.sub (f64.div (local.get $sum2) (f64.convert_i32_s (local.get $period)))
                     (f64.mul (local.get $mean) (local.get $mean))))
          (local.set $sd (f64.sqrt (call $max_f64 (local.get $variance) (f64.const 0))))
          (f64.store (i32.add (local.get $out) (i32.shl (local.get $i) (i32.const 3)))
            (local.get $mean))
          (f64.store (i32.add (i32.add (local.get $out) (i32.shl (local.get $cnt) (i32.const 3)))
                      (i32.shl (local.get $i) (i32.const 3)))
            (f64.add (local.get $mean) (f64.mul (local.get $mult) (local.get $sd))))
          (f64.store (i32.add (i32.add (local.get $out) (i32.shl (i32.mul (local.get $cnt) (i32.const 2)) (i32.const 3)))
                      (i32.shl (local.get $i) (i32.const 3)))
            (f64.sub (local.get $mean) (f64.mul (local.get $mult) (local.get $sd))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; ── RSI ───────────────────────────────────────────────────────────────
  (func $compute_rsi
    (param $id i32) (param $period i32) (param $out i32) (param $cnt i32)
    (local $i i32) (local $prev f64) (local $cur f64) (local $chg f64)
    (local $ag f64) (local $al f64) (local $k f64)
    (local.set $k (f64.div (f64.const 1.0) (f64.convert_i32_s (local.get $period))))
    (local.set $i (i32.const 0))
    (local.set $ag (f64.const 0))
    (local.set $al (f64.const 0))
    ;; seed on first period bars
    (block $seed_brk (loop $seed
      (br_if $seed_brk (i32.ge_s (local.get $i) (local.get $period)))
      (f64.store (i32.add (local.get $out) (i32.shl (local.get $i) (i32.const 3))) (f64.const 50))
      (if (i32.gt_s (local.get $i) (i32.const 0))
        (then
          (local.set $prev (call $ds_val (local.get $id) (i32.sub (local.get $i) (i32.const 1))))
          (local.set $cur  (call $ds_val (local.get $id) (local.get $i)))
          (local.set $chg  (f64.sub (local.get $cur) (local.get $prev)))
          (if (f64.gt (local.get $chg) (f64.const 0))
            (then (local.set $ag (f64.add (local.get $ag) (f64.mul (local.get $chg) (local.get $k)))))
            (else (local.set $al (f64.add (local.get $al)
                    (f64.mul (f64.neg (local.get $chg)) (local.get $k))))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $seed)))
    ;; main loop with Wilder smoothing
    (block $brk (loop $lp
      (br_if $brk (i32.ge_s (local.get $i) (local.get $cnt)))
      (local.set $prev (call $ds_val (local.get $id) (i32.sub (local.get $i) (i32.const 1))))
      (local.set $cur  (call $ds_val (local.get $id) (local.get $i)))
      (local.set $chg  (f64.sub (local.get $cur) (local.get $prev)))
      (local.set $ag
        (f64.div
          (f64.add (f64.mul (local.get $ag) (f64.convert_i32_s (i32.sub (local.get $period) (i32.const 1))))
                   (call $max_f64 (local.get $chg) (f64.const 0)))
          (f64.convert_i32_s (local.get $period))))
      (local.set $al
        (f64.div
          (f64.add (f64.mul (local.get $al) (f64.convert_i32_s (i32.sub (local.get $period) (i32.const 1))))
                   (call $max_f64 (f64.neg (local.get $chg)) (f64.const 0)))
          (f64.convert_i32_s (local.get $period))))
      (f64.store (i32.add (local.get $out) (i32.shl (local.get $i) (i32.const 3)))
        (select (f64.const 50)
          (f64.sub (f64.const 100)
            (f64.div (f64.const 100)
              (f64.add (f64.const 1)
                (f64.div (local.get $ag) (local.get $al)))))
          (f64.eq (local.get $al) (f64.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; ── MACD ─────────────────────────────────────────────────────────────
  ;; Stores: macd line at out[i], signal at (out+cnt*8)[i], histogram at (out+cnt*16)[i]
  ;; Uses param1=fast(12), param2=slow(26), param3=signal(9)
  (func $compute_macd
    (param $ip i32) (param $id i32) (param $out i32) (param $cnt i32)
    (local $fast i32) (local $slow i32) (local $signal_p i32)
    (local $i i32) (local $v f64) (local $ef f64) (local $es f64) (local $esig f64)
    (local $kf f64) (local $ks f64) (local $ksig f64)
    (local $macd_val f64) (local $sig_ptr i32) (local $hist_ptr i32)
    ;; default MACD params
    (local.set $fast    (i32.trunc_sat_f64_s (call $max_f64 (f64.load offset=24 (local.get $ip)) (f64.const 1))))
    (local.set $slow    (i32.trunc_sat_f64_s (call $max_f64 (f64.load offset=32 (local.get $ip)) (f64.const 1))))
    (local.set $signal_p (i32.trunc_sat_f64_s (call $max_f64 (f64.load offset=40 (local.get $ip)) (f64.const 1))))
    (if (i32.eqz (local.get $fast))    (then (local.set $fast    (i32.const 12))))
    (if (i32.eqz (local.get $slow))    (then (local.set $slow    (i32.const 26))))
    (if (i32.eqz (local.get $signal_p))(then (local.set $signal_p (i32.const 9))))
    (local.set $kf   (f64.div (f64.const 2.0) (f64.add (f64.convert_i32_s (local.get $fast))    (f64.const 1.0))))
    (local.set $ks   (f64.div (f64.const 2.0) (f64.add (f64.convert_i32_s (local.get $slow))    (f64.const 1.0))))
    (local.set $ksig (f64.div (f64.const 2.0) (f64.add (f64.convert_i32_s (local.get $signal_p)) (f64.const 1.0))))
    (local.set $sig_ptr  (i32.add (local.get $out) (i32.shl (local.get $cnt) (i32.const 3))))
    (local.set $hist_ptr (i32.add (local.get $out) (i32.shl (i32.mul (local.get $cnt) (i32.const 2)) (i32.const 3))))
    (local.set $i (i32.const 0))
    (local.set $ef   (f64.const 0))
    (local.set $es   (f64.const 0))
    (local.set $esig (f64.const 0))
    (block $brk (loop $lp
      (br_if $brk (i32.ge_s (local.get $i) (local.get $cnt)))
      (local.set $v (call $ds_val (local.get $id) (local.get $i)))
      (if (i32.eqz (local.get $i))
        (then
          (local.set $ef (local.get $v))
          (local.set $es (local.get $v))
          (local.set $esig (f64.const 0)))
        (else
          (local.set $ef
            (f64.add (f64.mul (local.get $v) (local.get $kf))
                     (f64.mul (local.get $ef) (f64.sub (f64.const 1.0) (local.get $kf)))))
          (local.set $es
            (f64.add (f64.mul (local.get $v) (local.get $ks))
                     (f64.mul (local.get $es) (f64.sub (f64.const 1.0) (local.get $ks)))))))
      (local.set $macd_val (f64.sub (local.get $ef) (local.get $es)))
      (if (i32.eqz (local.get $i))
        (then (local.set $esig (local.get $macd_val)))
        (else
          (local.set $esig
            (f64.add (f64.mul (local.get $macd_val) (local.get $ksig))
                     (f64.mul (local.get $esig) (f64.sub (f64.const 1.0) (local.get $ksig)))))))
      (f64.store (i32.add (local.get $out)      (i32.shl (local.get $i) (i32.const 3))) (local.get $macd_val))
      (f64.store (i32.add (local.get $sig_ptr)  (i32.shl (local.get $i) (i32.const 3))) (local.get $esig))
      (f64.store (i32.add (local.get $hist_ptr) (i32.shl (local.get $i) (i32.const 3)))
        (f64.sub (local.get $macd_val) (local.get $esig)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; ── 3×5 pixel font (15-bit row-major bitmaps, stored at 0x3E00) ────────────
  ;; Index:  0-9 = digits, 10='.', 11='-', 12=' ', 13=':', 14='K', 15='M'
  ;; Encoding: bits[14:12]=row0, bits[11:9]=row1, …, bits[2:0]=row4  (MSB=left)
  (func $init_font
    (i32.store (i32.const 0x3E00) (i32.const 31599))  ;; '0' ###/#.#/#.#/#.#/###
    (i32.store (i32.const 0x3E04) (i32.const 11415))  ;; '1' .#./##./.#./.#./###
    (i32.store (i32.const 0x3E08) (i32.const 29671))  ;; '2' ###/..#/###/#../###
    (i32.store (i32.const 0x3E0C) (i32.const 29391))  ;; '3' ###/..#/.##/..#/###
    (i32.store (i32.const 0x3E10) (i32.const 23497))  ;; '4' #.#/#.#/###/..#/..#
    (i32.store (i32.const 0x3E14) (i32.const 31183))  ;; '5' ###/#../###/..#/###
    (i32.store (i32.const 0x3E18) (i32.const 31215))  ;; '6' ###/#../###/#.#/###
    (i32.store (i32.const 0x3E1C) (i32.const 29257))  ;; '7' ###/..#/..#/..#/..#
    (i32.store (i32.const 0x3E20) (i32.const 31727))  ;; '8' ###/#.#/###/#.#/###
    (i32.store (i32.const 0x3E24) (i32.const 31695))  ;; '9' ###/#.#/###/..#/###
    (i32.store (i32.const 0x3E28) (i32.const 2))      ;; '.' .../.../.../.../. #.
    (i32.store (i32.const 0x3E2C) (i32.const 448))    ;; '-' .../.../ ###/.../...
    (i32.store (i32.const 0x3E30) (i32.const 0))      ;; ' ' blank
    (i32.store (i32.const 0x3E34) (i32.const 1040))   ;; ':' .../.#./.../.#./...
    (i32.store (i32.const 0x3E38) (i32.const 23469))  ;; 'K' #.#/#.#/##./#.#/#.#
    (i32.store (i32.const 0x3E3C) (i32.const 31597))) ;; 'M' ###/#.#/#.#/#.#/#.#

  ;; Draw a single 3×5 character (index $idx) at pixel (x, y) in colour $col
  (func $draw_char (param $x i32) (param $y i32) (param $idx i32) (param $col i32)
    (local $bits i32) (local $row i32) (local $rbits i32)
    (local.set $bits (i32.load (i32.add (i32.const 0x3E00) (i32.shl (local.get $idx) (i32.const 2)))))
    (local.set $row (i32.const 0))
    (block $brk (loop $lp
      (br_if $brk (i32.ge_s (local.get $row) (i32.const 5)))
      ;; extract 3 bits for this row: bits[(4-row)*3 + 2 : (4-row)*3]
      (local.set $rbits
        (i32.and
          (i32.shr_u (local.get $bits)
            (i32.mul (i32.sub (i32.const 4) (local.get $row)) (i32.const 3)))
          (i32.const 7)))
      (if (i32.and (local.get $rbits) (i32.const 4))
        (then (call $fb_blend (local.get $x)
                (i32.add (local.get $y) (local.get $row)) (local.get $col))))
      (if (i32.and (local.get $rbits) (i32.const 2))
        (then (call $fb_blend (i32.add (local.get $x) (i32.const 1))
                (i32.add (local.get $y) (local.get $row)) (local.get $col))))
      (if (i32.and (local.get $rbits) (i32.const 1))
        (then (call $fb_blend (i32.add (local.get $x) (i32.const 2))
                (i32.add (local.get $y) (local.get $row)) (local.get $col))))
      (local.set $row (i32.add (local.get $row) (i32.const 1)))
      (br $lp))))

  ;; Write decimal digits of non-negative i64 into scratch buf at 0x3F00.
  ;; Returns number of chars written.  Each byte is a font index (0-9 for digits,
  ;; 10 for '.', 11 for '-').  Handles sign, integer and 1 optional decimal place.
  ;; $decimals: number of decimal digits to show (0 or 1)
  (func $fmt_price (param $val f64) (param $decimals i32) (result i32)
    (local $neg i32) (local $int_part i64) (local $frac i64)
    (local $n i32) (local $tmp i32) (local $rem i64) (local $c i32)
    ;; scratch: 0x3F00 = char-index buffer (forward), 0x3F20 = reverse temp
    (local.set $neg (i32.const 0))
    (if (f64.lt (local.get $val) (f64.const 0))
      (then
        (local.set $neg (i32.const 1))
        (local.set $val (f64.neg (local.get $val)))))
    ;; round to 1 decimal place max
    (if (local.get $decimals)
      (then
        (local.set $int_part (i64.trunc_sat_f64_s (local.get $val)))
        (local.set $frac
          (i64.trunc_sat_f64_s
            (f64.nearest (f64.mul
              (f64.sub (local.get $val) (f64.convert_i64_s (local.get $int_part)))
              (f64.const 10))))))
      (else
        (local.set $int_part (i64.trunc_sat_f64_s (f64.nearest (local.get $val))))
        (local.set $frac (i64.const 0))))
    ;; write reversed digits into 0x3F20, then copy forward
    (local.set $n (i32.const 0))
    (local.set $rem (local.get $int_part))
    (if (i64.eqz (local.get $rem))
      (then
        (i32.store8 (i32.const 0x3F20) (i32.const 0))
        (local.set $n (i32.const 1)))
      (else
        (block $brk (loop $lp
          (br_if $brk (i64.eqz (local.get $rem)))
          (i32.store8 (i32.add (i32.const 0x3F20) (local.get $n))
            (i32.wrap_i64 (i64.rem_u (local.get $rem) (i64.const 10))))
          (local.set $rem (i64.div_u (local.get $rem) (i64.const 10)))
          (local.set $n (i32.add (local.get $n) (i32.const 1)))
          (br $lp)))))
    ;; optional decimal suffix (digit + '.')
    (if (local.get $decimals)
      (then
        (i32.store8 (i32.add (i32.const 0x3F20) (local.get $n)) (i32.wrap_i64 (local.get $frac)))
        (local.set $n (i32.add (local.get $n) (i32.const 1)))
        (i32.store8 (i32.add (i32.const 0x3F20) (local.get $n)) (i32.const 10)) ;; '.'
        (local.set $n (i32.add (local.get $n) (i32.const 1)))))
    ;; negative sign
    (if (local.get $neg)
      (then
        (i32.store8 (i32.add (i32.const 0x3F20) (local.get $n)) (i32.const 11)) ;; '-'
        (local.set $n (i32.add (local.get $n) (i32.const 1)))))
    ;; reverse into 0x3F00
    (local.set $tmp (i32.const 0))
    (block $rb (loop $rl
      (br_if $rb (i32.ge_s (local.get $tmp) (local.get $n)))
      (i32.store8 (i32.add (i32.const 0x3F00) (local.get $tmp))
        (i32.load8_u (i32.add (i32.const 0x3F20)
          (i32.sub (i32.sub (local.get $n) (local.get $tmp)) (i32.const 1)))))
      (local.set $tmp (i32.add (local.get $tmp) (i32.const 1)))
      (br $rl)))
    (local.get $n))

  ;; Draw a string from the 0x3F00 buffer ($len chars) right-aligned ending at $x_end
  (func $draw_rstr (param $x_end i32) (param $y i32) (param $len i32) (param $col i32)
    (local $x i32) (local $j i32)
    ;; each char is 3 pixels wide + 1 gap = 4 pixels; start x = x_end - len*4 + 1
    (local.set $x (i32.sub (local.get $x_end) (i32.sub (i32.mul (local.get $len) (i32.const 4)) (i32.const 1))))
    (local.set $j (i32.const 0))
    (block $brk (loop $lp
      (br_if $brk (i32.ge_s (local.get $j) (local.get $len)))
      (call $draw_char (local.get $x) (local.get $y)
        (i32.load8_u (i32.add (i32.const 0x3F00) (local.get $j)))
        (local.get $col))
      (local.set $x (i32.add (local.get $x) (i32.const 4)))
      (local.set $j (i32.add (local.get $j) (i32.const 1)))
      (br $lp))))

  ;; Y-axis price labels: render 5 price values at the 5 grid line positions
  (func $render_price_labels
    (local $step f64) (local $val f64) (local $i i32) (local $y i32) (local $col i32)
    (local $n i32)
    (local.set $col (call $text_col))
    (local.set $step (f64.div (f64.sub (call $pmax) (call $pmin)) (f64.const 5)))
    (local.set $i (i32.const 0))
    (block $brk (loop $lp
      (br_if $brk (i32.gt_s (local.get $i) (i32.const 4)))
      ;; value at this grid line (pmax at top, pmin at bottom; label at gridline i from bottom)
      (local.set $val (f64.add (call $pmin) (f64.mul (f64.convert_i32_s (local.get $i)) (local.get $step))))
      (local.set $y
        (i32.sub (i32.add (call $cy) (call $cah))
          (i32.trunc_sat_f64_s
            (f64.mul (f64.div
              (f64.sub (local.get $val) (call $pmin))
              (f64.sub (call $pmax) (call $pmin)))
              (f64.convert_i32_s (call $cah))))))
      ;; format with 1 decimal if price < 100, else 0
      (local.set $n (call $fmt_price (local.get $val)
        (select (i32.const 1) (i32.const 0)
          (f64.lt (call $abs_f64 (local.get $val)) (f64.const 100)))))
      ;; right-align in left margin (end at cx-2)
      (call $draw_rstr (i32.sub (call $cx) (i32.const 2))
        (i32.sub (local.get $y) (i32.const 3)) (local.get $n) (local.get $col))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; X-axis date labels: decode Unix-ms timestamp → day-of-month digits + "/" + month digits
  ;; Simplified: just shows "DD" (day number) at ~4 evenly spaced positions along X axis
  (func $render_time_labels
    (local $id i32) (local $n i32) (local $s i32) (local $e i32) (local $step i32)
    (local $i i32) (local $p i32) (local $ts i64) (local $day i64) (local $x i32)
    (local $month i64) (local $dom i64) (local $col i32) (local $nc i32)
    (local.set $id (call $active_ds))
    (if (i32.lt_s (local.get $id) (i32.const 0)) (then (return)))
    (local.set $n (call $ds_cnt (local.get $id)))
    (if (i32.eqz (local.get $n)) (then (return)))
    (local.set $s (call $ds_lower_bound (local.get $id) (call $view_s)))
    (local.set $e (call $ds_upper_bound (local.get $id) (call $view_e)))
    (if (i32.ge_s (local.get $s) (local.get $e)) (then (return)))
    (local.set $col (call $text_col))
    ;; render ~5 labels evenly spaced across the visible range
    (local.set $step (call $max_i32 (i32.const 1) (i32.div_u (i32.sub (local.get $e) (local.get $s)) (i32.const 4))))
    (local.set $i (local.get $s))
    (block $brk (loop $lp
      (br_if $brk (i32.gt_s (local.get $i) (local.get $e)))
      (local.set $p  (call $ds_rec_ptr (local.get $id) (local.get $i)))
      (local.set $ts (i64.load (local.get $p)))
      ;; days since Unix epoch = ts_ms / 86_400_000
      (local.set $day (i64.div_u (local.get $ts) (i64.const 86400000)))
      ;; simple day-of-month: day mod 30 + 1  (not calendar-accurate but avoids complex arithmetic)
      (local.set $dom (i64.add (i64.rem_u (local.get $day) (i64.const 30)) (i64.const 1)))
      ;; month bucket: (day / 30) mod 12 + 1
      (local.set $month (i64.add (i64.rem_u (i64.div_u (local.get $day) (i64.const 30)) (i64.const 12)) (i64.const 1)))
      (local.set $x (call $time_to_x (local.get $ts)))
      ;; format MM/DD into scratch buffer (reuse 0x3F00)
      ;; write month tens digit
      (local.set $nc (i32.const 0))
      (if (i64.ge_u (local.get $month) (i64.const 10))
        (then
          (i32.store8 (i32.const 0x3F00) (i32.wrap_i64 (i64.div_u (local.get $month) (i64.const 10))))
          (local.set $nc (i32.const 1))))
      (i32.store8 (i32.add (i32.const 0x3F00) (local.get $nc))
        (i32.wrap_i64 (i64.rem_u (local.get $month) (i64.const 10))))
      (local.set $nc (i32.add (local.get $nc) (i32.const 1)))
      (i32.store8 (i32.add (i32.const 0x3F00) (local.get $nc)) (i32.const 12)) ;; '/' → use 'K' slot? no, use space
      ;; Actually use '-' (idx 11) as separator
      (i32.store8 (i32.add (i32.const 0x3F00) (local.get $nc)) (i32.const 11))
      (local.set $nc (i32.add (local.get $nc) (i32.const 1)))
      ;; day-of-month tens
      (if (i64.ge_u (local.get $dom) (i64.const 10))
        (then
          (i32.store8 (i32.add (i32.const 0x3F00) (local.get $nc))
            (i32.wrap_i64 (i64.div_u (local.get $dom) (i64.const 10))))
          (local.set $nc (i32.add (local.get $nc) (i32.const 1)))))
      (i32.store8 (i32.add (i32.const 0x3F00) (local.get $nc))
        (i32.wrap_i64 (i64.rem_u (local.get $dom) (i64.const 10))))
      (local.set $nc (i32.add (local.get $nc) (i32.const 1)))
      ;; draw centered under X
      (call $draw_rstr (i32.add (local.get $x) (i32.const 1))
        (i32.add (i32.add (call $cy) (call $cah)) (i32.const 2))
        (local.get $nc) (local.get $col))
      (local.set $i (i32.add (local.get $i) (local.get $step)))
      (br $lp))))

  ;; Indicator sub-panel: grid + labels
  (func $render_ind_panel_grid
    (local $gc i32) (local $py i32) (local $ph i32)
    (if (i32.eqz (call $ind_ps)) (then (return)))
    (local.set $gc (call $grid_col))
    (local.set $py (i32.add (call $cy) (call $cah)))
    (local.set $ph (call $ind_ph))
    ;; outline
    (call $draw_rect_outline (call $cx) (local.get $py) (call $caw) (local.get $ph) (local.get $gc))
    ;; mid-line
    (call $draw_hline (call $cx) (i32.add (call $cx) (call $caw))
      (i32.add (local.get $py) (i32.shr_u (local.get $ph) (i32.const 1))) (local.get $gc)))

  ;; Map a value to the indicator panel Y coordinate
  (func $ind_val_to_py (param $val f64) (result i32)
    (local $mn f64) (local $mx f64) (local $h i32) (local $base i32)
    (local.set $mn   (call $ind_pmin))
    (local.set $mx   (call $ind_pmax))
    (local.set $h    (call $ind_ph))
    (local.set $base (i32.add (call $cy) (call $cah)))
    (if (f64.eq (local.get $mn) (local.get $mx))
      (then (return (i32.add (local.get $base) (i32.shr_u (local.get $h) (i32.const 1))))))
    (i32.add (local.get $base)
      (i32.sub (i32.sub (local.get $h) (i32.const 1))
        (i32.trunc_sat_f64_s
          (f64.mul
            (f64.div (f64.sub (local.get $val) (local.get $mn))
                     (f64.sub (local.get $mx) (local.get $mn)))
            (f64.convert_i32_s (local.get $h)))))))

  ;; Standalone volume chart that fills the full chart area (chart_type = 4)
  (func $render_volume_main
    (local $id i32) (local $n i32) (local $s i32) (local $e i32) (local $i i32)
    (local $p i32) (local $ts i64) (local $vol f64) (local $open f64) (local $close f64)
    (local $x i32) (local $bw i32) (local $vbase i32) (local $vh i32)
    (local $col i32) (local $vpy i32) (local $maxvol f64)
    (local.set $id (call $active_ds))
    (if (i32.lt_s (local.get $id) (i32.const 0)) (then (return)))
    (if (call $ds_type_of (local.get $id)) (then (return)))  ;; OHLCV only
    (local.set $n (call $ds_cnt (local.get $id)))
    (if (i32.eqz (local.get $n)) (then (return)))
    (local.set $s (call $ds_lower_bound (local.get $id) (call $view_s)))
    (local.set $e (call $ds_upper_bound (local.get $id) (call $view_e)))
    (if (i32.gt_s (local.get $s) (local.get $e)) (then (return)))
    (local.set $vh    (call $cah))
    (local.set $vbase (i32.sub (i32.add (call $cy) (call $cah)) (i32.const 1)))
    (local.set $bw (call $max_i32 (i32.const 1)
      (i32.sub (i32.div_u (call $caw)
        (i32.add (i32.sub (local.get $e) (local.get $s)) (i32.const 1))) (i32.const 1))))
    ;; find max volume
    (local.set $maxvol (f64.const 1.0))
    (local.set $i (local.get $s))
    (block $b1 (loop $l1
      (br_if $b1 (i32.gt_s (local.get $i) (local.get $e)))
      (local.set $vol (f64.load offset=40 (call $ds_rec_ptr (local.get $id) (local.get $i))))
      (if (f64.gt (local.get $vol) (local.get $maxvol)) (then (local.set $maxvol (local.get $vol))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l1)))
    (local.set $i (local.get $s))
    (block $b2 (loop $l2
      (br_if $b2 (i32.gt_s (local.get $i) (local.get $e)))
      (local.set $p     (call $ds_rec_ptr (local.get $id) (local.get $i)))
      (local.set $ts    (i64.load (local.get $p)))
      (local.set $open  (f64.load offset=8  (local.get $p)))
      (local.set $close (f64.load offset=32 (local.get $p)))
      (local.set $vol   (f64.load offset=40 (local.get $p)))
      (local.set $x (call $time_to_x (local.get $ts)))
      (local.set $vpy
        (i32.sub (local.get $vbase)
          (i32.trunc_sat_f64_s
            (f64.mul (f64.div (local.get $vol) (local.get $maxvol))
                     (f64.convert_i32_s (local.get $vh))))))
      (local.set $col (select (call $up_col) (call $dn_col)
        (f64.ge (local.get $close) (local.get $open))))
      (local.set $col (call $pack_rgba
        (call $ch_r (local.get $col)) (call $ch_g (local.get $col))
        (call $ch_b (local.get $col)) (i32.const 200)))
      (call $draw_rect
        (i32.sub (local.get $x) (i32.shr_s (local.get $bw) (i32.const 1)))
        (local.get $vpy)
        (local.get $bw)
        (i32.add (i32.sub (local.get $vbase) (local.get $vpy)) (i32.const 1))
        (local.get $col))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l2))))

  ;; ── grid ──────────────────────────────────────────────────────────────
  (func $render_grid
    (local $gc i32) (local $step i32) (local $i i32) (local $y i32)
    (local.set $gc (call $grid_col))
    ;; 4 horizontal grid lines dividing chart height into 5 equal sections
    (local.set $step (i32.div_u (call $cah) (i32.const 5)))
    (local.set $i (i32.const 1))
    (block $brk (loop $lp
      (br_if $brk (i32.gt_s (local.get $i) (i32.const 4)))
      (local.set $y (i32.add (call $cy) (i32.mul (local.get $i) (local.get $step))))
      (call $draw_hline (call $cx) (i32.add (call $cx) (call $caw)) (local.get $y) (local.get $gc))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    ;; border outline
    (call $draw_rect_outline (call $cx) (call $cy) (call $caw) (call $cah) (local.get $gc)))

  ;; ── candlestick ───────────────────────────────────────────────────────
  (func $render_candlestick
    (local $id i32) (local $n i32) (local $s i32) (local $e i32) (local $i i32)
    (local $p i32) (local $ts i64)
    (local $open f64) (local $high f64) (local $low f64) (local $close f64)
    (local $x i32) (local $yo i32) (local $yh i32) (local $yl i32) (local $yc i32)
    (local $col i32) (local $bw i32) (local $vc i32)
    (local.set $id (call $active_ds))
    (if (i32.lt_s (local.get $id) (i32.const 0)) (then (return)))
    (local.set $n (call $ds_cnt (local.get $id)))
    (if (i32.eqz (local.get $n)) (then (return)))
    (local.set $s (call $ds_lower_bound (local.get $id) (call $view_s)))
    (local.set $e (call $ds_upper_bound (local.get $id) (call $view_e)))
    (if (i32.gt_s (local.get $s) (local.get $e)) (then (return)))
    (local.set $vc (i32.add (i32.sub (local.get $e) (local.get $s)) (i32.const 1)))
    (local.set $bw (call $max_i32 (i32.const 1)
      (i32.sub (i32.div_u (call $caw) (local.get $vc)) (i32.const 1))))
    (local.set $i (local.get $s))
    (block $brk (loop $lp
      (br_if $brk (i32.gt_s (local.get $i) (local.get $e)))
      (local.set $p (call $ds_rec_ptr (local.get $id) (local.get $i)))
      (local.set $ts    (i64.load     (local.get $p)))
      (local.set $open  (f64.load offset=8  (local.get $p)))
      (local.set $high  (f64.load offset=16 (local.get $p)))
      (local.set $low   (f64.load offset=24 (local.get $p)))
      (local.set $close (f64.load offset=32 (local.get $p)))
      (local.set $x  (call $time_to_x (local.get $ts)))
      (local.set $yo (call $price_to_y (local.get $open)))
      (local.set $yh (call $price_to_y (local.get $high)))
      (local.set $yl (call $price_to_y (local.get $low)))
      (local.set $yc (call $price_to_y (local.get $close)))
      (local.set $col (select (call $up_col) (call $dn_col)
        (f64.ge (local.get $close) (local.get $open))))
      ;; wick
      (call $draw_vline (local.get $x) (local.get $yh) (local.get $yl) (local.get $col))
      ;; body
      (call $draw_rect
        (i32.sub (local.get $x) (i32.shr_s (local.get $bw) (i32.const 1)))
        (call $min_i32 (local.get $yo) (local.get $yc))
        (local.get $bw)
        (call $max_i32 (i32.sub (call $max_i32 (local.get $yo) (local.get $yc))
                                (call $min_i32 (local.get $yo) (local.get $yc))) (i32.const 1))
        (local.get $col))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; ── OHLC bar ──────────────────────────────────────────────────────────
  (func $render_ohlc_bar
    (local $id i32) (local $n i32) (local $s i32) (local $e i32) (local $i i32)
    (local $p i32) (local $ts i64)
    (local $open f64) (local $high f64) (local $low f64) (local $close f64)
    (local $x i32) (local $yo i32) (local $yh i32) (local $yl i32) (local $yc i32)
    (local $col i32) (local $tw i32) (local $vc i32)
    (local.set $id (call $active_ds))
    (if (i32.lt_s (local.get $id) (i32.const 0)) (then (return)))
    (local.set $n (call $ds_cnt (local.get $id)))
    (if (i32.eqz (local.get $n)) (then (return)))
    (local.set $s (call $ds_lower_bound (local.get $id) (call $view_s)))
    (local.set $e (call $ds_upper_bound (local.get $id) (call $view_e)))
    (if (i32.gt_s (local.get $s) (local.get $e)) (then (return)))
    (local.set $vc (i32.add (i32.sub (local.get $e) (local.get $s)) (i32.const 1)))
    (local.set $tw (call $max_i32 (i32.const 2)
      (i32.div_u (call $caw) (i32.mul (local.get $vc) (i32.const 4)))))
    (local.set $i (local.get $s))
    (block $brk (loop $lp
      (br_if $brk (i32.gt_s (local.get $i) (local.get $e)))
      (local.set $p (call $ds_rec_ptr (local.get $id) (local.get $i)))
      (local.set $ts    (i64.load     (local.get $p)))
      (local.set $open  (f64.load offset=8  (local.get $p)))
      (local.set $high  (f64.load offset=16 (local.get $p)))
      (local.set $low   (f64.load offset=24 (local.get $p)))
      (local.set $close (f64.load offset=32 (local.get $p)))
      (local.set $x  (call $time_to_x (local.get $ts)))
      (local.set $yo (call $price_to_y (local.get $open)))
      (local.set $yh (call $price_to_y (local.get $high)))
      (local.set $yl (call $price_to_y (local.get $low)))
      (local.set $yc (call $price_to_y (local.get $close)))
      (local.set $col (select (call $up_col) (call $dn_col)
        (f64.ge (local.get $close) (local.get $open))))
      (call $draw_vline (local.get $x) (local.get $yh) (local.get $yl) (local.get $col))
      (call $draw_hline (i32.sub (local.get $x) (local.get $tw)) (local.get $x) (local.get $yo) (local.get $col))
      (call $draw_hline (local.get $x) (i32.add (local.get $x) (local.get $tw)) (local.get $yc) (local.get $col))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; Returns typical time step for dataset (first two bars; 0 if fewer than 2 bars)
  (func $ds_typical_step (param $id i32) (result i64)
    (if (i32.lt_s (call $ds_cnt (local.get $id)) (i32.const 2)) (then (return (i64.const 0))))
    (i64.sub
      (i64.load (call $ds_rec_ptr (local.get $id) (i32.const 1)))
      (i64.load (call $ds_rec_ptr (local.get $id) (i32.const 0)))))

  ;; ── line chart ────────────────────────────────────────────────────────
  ;; Segments that span more than 2× the typical step are skipped (visible gap).
  (func $render_line
    (local $id i32) (local $n i32) (local $s i32) (local $e i32) (local $i i32)
    (local $p i32) (local $ts i64) (local $val f64) (local $prev_ts i64)
    (local $x i32) (local $y i32) (local $px i32) (local $py i32)
    (local $col i32) (local $r i32) (local $g i32) (local $b i32)
    (local $step i64) (local $thresh i64)
    (local.set $id (call $active_ds))
    (if (i32.lt_s (local.get $id) (i32.const 0)) (then (return)))
    (local.set $n (call $ds_cnt (local.get $id)))
    (if (i32.eqz (local.get $n)) (then (return)))
    (local.set $s (call $ds_lower_bound (local.get $id) (call $view_s)))
    (local.set $e (call $ds_upper_bound (local.get $id) (call $view_e)))
    (if (i32.gt_s (local.get $s) (local.get $e)) (then (return)))
    (local.set $step   (call $ds_typical_step (local.get $id)))
    (local.set $thresh (i64.mul (local.get $step) (i64.const 2)))
    (local.set $col (call $ln_col))
    (local.set $r (call $ch_r (local.get $col)))
    (local.set $g (call $ch_g (local.get $col)))
    (local.set $b (call $ch_b (local.get $col)))
    (local.set $px      (i32.const -1))
    (local.set $prev_ts (i64.const 0))
    (local.set $i (local.get $s))
    (block $brk (loop $lp
      (br_if $brk (i32.gt_s (local.get $i) (local.get $e)))
      (local.set $p (call $ds_rec_ptr (local.get $id) (local.get $i)))
      (local.set $ts  (i64.load (local.get $p)))
      (local.set $val (call $ds_val (local.get $id) (local.get $i)))
      (local.set $x (call $time_to_x (local.get $ts)))
      (local.set $y (call $price_to_y (local.get $val)))
      (if (i32.ge_s (local.get $px) (i32.const 0))
        (then
          ;; If gap > 2× step, break the polyline (visible gap = no interpolation across weekends etc.)
          (if (i32.or
                (i64.eqz (local.get $step))
                (i64.le_s (i64.sub (local.get $ts) (local.get $prev_ts)) (local.get $thresh)))
            (then (call $draw_aa_line (local.get $px) (local.get $py)
                    (local.get $x) (local.get $y) (local.get $r) (local.get $g) (local.get $b)))
            (else (local.set $px (i32.const -1))))))  ;; skip segment, reset pen
      (local.set $px      (local.get $x))
      (local.set $py      (local.get $y))
      (local.set $prev_ts (local.get $ts))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; ── area chart ────────────────────────────────────────────────────────
  ;; Same gap-aware rendering: skip fill and outline for segments crossing gaps.
  (func $render_area
    (local $id i32) (local $n i32) (local $s i32) (local $e i32) (local $i i32)
    (local $p i32) (local $ts i64) (local $val f64) (local $prev_ts i64)
    (local $x i32) (local $y i32) (local $px i32) (local $py i32)
    (local $col i32) (local $fill i32) (local $r i32) (local $g i32) (local $b i32)
    (local $base_y i32) (local $step i64) (local $thresh i64)
    (local.set $id (call $active_ds))
    (if (i32.lt_s (local.get $id) (i32.const 0)) (then (return)))
    (local.set $n (call $ds_cnt (local.get $id)))
    (if (i32.eqz (local.get $n)) (then (return)))
    (local.set $s (call $ds_lower_bound (local.get $id) (call $view_s)))
    (local.set $e (call $ds_upper_bound (local.get $id) (call $view_e)))
    (if (i32.gt_s (local.get $s) (local.get $e)) (then (return)))
    (local.set $step   (call $ds_typical_step (local.get $id)))
    (local.set $thresh (i64.mul (local.get $step) (i64.const 2)))
    (local.set $col (call $ln_col))
    (local.set $r (call $ch_r (local.get $col)))
    (local.set $g (call $ch_g (local.get $col)))
    (local.set $b (call $ch_b (local.get $col)))
    (local.set $fill (call $pack_rgba (local.get $r) (local.get $g) (local.get $b) (i32.const 55)))
    (local.set $base_y (i32.sub (i32.add (call $cy) (call $cah)) (i32.const 1)))
    (local.set $px      (i32.const -1))
    (local.set $prev_ts (i64.const 0))
    (local.set $i (local.get $s))
    (block $brk (loop $lp
      (br_if $brk (i32.gt_s (local.get $i) (local.get $e)))
      (local.set $p (call $ds_rec_ptr (local.get $id) (local.get $i)))
      (local.set $ts  (i64.load (local.get $p)))
      (local.set $val (call $ds_val (local.get $id) (local.get $i)))
      (local.set $x (call $time_to_x (local.get $ts)))
      (local.set $y (call $price_to_y (local.get $val)))
      (if (i32.ge_s (local.get $px) (i32.const 0))
        (then
          (if (i32.or
                (i64.eqz (local.get $step))
                (i64.le_s (i64.sub (local.get $ts) (local.get $prev_ts)) (local.get $thresh)))
            (then
              (call $fill_trapezoid (local.get $px) (local.get $py)
                (local.get $x) (local.get $y) (local.get $base_y) (local.get $fill))
              (call $draw_aa_line (local.get $px) (local.get $py)
                (local.get $x) (local.get $y) (local.get $r) (local.get $g) (local.get $b)))
            (else (local.set $px (i32.const -1))))))
      (local.set $px      (local.get $x))
      (local.set $py      (local.get $y))
      (local.set $prev_ts (local.get $ts))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; ── volume panel ──────────────────────────────────────────────────────
  (func $render_volume
    (local $id i32) (local $n i32) (local $s i32) (local $e i32) (local $i i32)
    (local $p i32) (local $ts i64) (local $vol f64) (local $open f64) (local $close f64)
    (local $x i32) (local $bw i32) (local $vc i32)
    (local $col i32) (local $vbase i32) (local $vh i32) (local $vpy i32) (local $maxvol f64)
    (local.set $id (call $active_ds))
    (if (i32.lt_s (local.get $id) (i32.const 0)) (then (return)))
    (if (call $ds_type_of (local.get $id)) (then (return)))  ;; OHLCV only
    (local.set $n (call $ds_cnt (local.get $id)))
    (if (i32.eqz (local.get $n)) (then (return)))
    (local.set $s (call $ds_lower_bound (local.get $id) (call $view_s)))
    (local.set $e (call $ds_upper_bound (local.get $id) (call $view_e)))
    (if (i32.gt_s (local.get $s) (local.get $e)) (then (return)))
    (local.set $vh    (call $vol_h))
    ;; vbase = bottom of volume panel (cy + cah + ind_panel_h + vol_h - 1)
    (local.set $vbase (i32.sub
      (i32.add (i32.add (call $cy) (call $cah))
               (select (call $ind_ph) (i32.const 0) (call $ind_ps)))
      (i32.const 0)))
    (local.set $vbase (i32.add (local.get $vbase) (local.get $vh)))
    (local.set $vbase (i32.sub (local.get $vbase) (i32.const 1)))
    (local.set $vc (i32.add (i32.sub (local.get $e) (local.get $s)) (i32.const 1)))
    (local.set $bw (call $max_i32 (i32.const 1)
      (i32.sub (i32.div_u (call $caw) (local.get $vc)) (i32.const 1))))
    ;; find max volume
    (local.set $maxvol (f64.const 1.0))
    (local.set $i (local.get $s))
    (block $b1 (loop $l1
      (br_if $b1 (i32.gt_s (local.get $i) (local.get $e)))
      (local.set $p (call $ds_rec_ptr (local.get $id) (local.get $i)))
      (local.set $vol (f64.load offset=40 (local.get $p)))
      (if (f64.gt (local.get $vol) (local.get $maxvol)) (then (local.set $maxvol (local.get $vol))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l1)))
    (local.set $i (local.get $s))
    (block $b2 (loop $l2
      (br_if $b2 (i32.gt_s (local.get $i) (local.get $e)))
      (local.set $p     (call $ds_rec_ptr (local.get $id) (local.get $i)))
      (local.set $ts    (i64.load (local.get $p)))
      (local.set $open  (f64.load offset=8  (local.get $p)))
      (local.set $close (f64.load offset=32 (local.get $p)))
      (local.set $vol   (f64.load offset=40 (local.get $p)))
      (local.set $x (call $time_to_x (local.get $ts)))
      (local.set $vpy
        (i32.sub (local.get $vbase)
          (i32.trunc_sat_f64_s
            (f64.mul (f64.div (local.get $vol) (local.get $maxvol))
                     (f64.convert_i32_s (local.get $vh))))))
      (local.set $col (select (call $up_col) (call $dn_col)
        (f64.ge (local.get $close) (local.get $open))))
      (local.set $col (call $pack_rgba
        (call $ch_r (local.get $col)) (call $ch_g (local.get $col))
        (call $ch_b (local.get $col)) (i32.const 180)))
      (call $draw_rect
        (i32.sub (local.get $x) (i32.shr_s (local.get $bw) (i32.const 1)))
        (local.get $vpy)
        (local.get $bw)
        (i32.add (i32.sub (local.get $vbase) (local.get $vpy)) (i32.const 1))
        (local.get $col))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l2))))

  ;; ── scatter ───────────────────────────────────────────────────────────
  (func $render_scatter
    (local $id i32) (local $n i32) (local $s i32) (local $e i32) (local $i i32)
    (local $p i32) (local $ts i64) (local $val f64)
    (local $x i32) (local $y i32) (local $col i32)
    (local.set $id (call $active_ds))
    (if (i32.lt_s (local.get $id) (i32.const 0)) (then (return)))
    (local.set $n (call $ds_cnt (local.get $id)))
    (if (i32.eqz (local.get $n)) (then (return)))
    (local.set $s (call $ds_lower_bound (local.get $id) (call $view_s)))
    (local.set $e (call $ds_upper_bound (local.get $id) (call $view_e)))
    (if (i32.gt_s (local.get $s) (local.get $e)) (then (return)))
    (local.set $col (call $ln_col))
    (local.set $i (local.get $s))
    (block $brk (loop $lp
      (br_if $brk (i32.gt_s (local.get $i) (local.get $e)))
      (local.set $p (call $ds_rec_ptr (local.get $id) (local.get $i)))
      (local.set $ts  (i64.load (local.get $p)))
      (local.set $val (call $ds_val (local.get $id) (local.get $i)))
      (local.set $x (call $time_to_x (local.get $ts)))
      (local.set $y (call $price_to_y (local.get $val)))
      (call $draw_rect
        (i32.sub (local.get $x) (i32.const 2))
        (i32.sub (local.get $y) (i32.const 2))
        (i32.const 5) (i32.const 5) (local.get $col))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; ── indicator line renderer ───────────────────────────────────────────
  (func $render_ind_line (param $ii i32) (param $offset_mult i32)
    (local $ip i32) (local $dp i32) (local $cnt i32) (local $col i32)
    (local $dsid i32) (local $s i32)
    (local $r i32) (local $g i32) (local $b i32)
    (local $i i32) (local $ts i64) (local $val f64)
    (local $x i32) (local $y i32) (local $px i32) (local $py i32)
    (local.set $ip  (call $ind_ptr (local.get $ii)))
    (local.set $cnt (i32.load offset=52 (local.get $ip)))
    (if (i32.eqz (local.get $cnt)) (then (return)))
    (local.set $col  (i32.load offset=16 (local.get $ip)))
    (local.set $dsid (i32.load offset=8  (local.get $ip)))
    (local.set $s    (call $ds_lower_bound (local.get $dsid) (call $view_s)))
    ;; data_ptr points to start of this band (mid=0, upper=1, lower=2)
    (local.set $dp
      (i32.add (i32.load offset=48 (local.get $ip))
               (i32.shl (i32.mul (local.get $offset_mult) (local.get $cnt)) (i32.const 3))))
    (local.set $r (call $ch_r (local.get $col)))
    (local.set $g (call $ch_g (local.get $col)))
    (local.set $b (call $ch_b (local.get $col)))
    (local.set $px (i32.const -1))
    (local.set $i  (local.get $s))
    (block $brk (loop $lp
      (br_if $brk (i32.ge_s (local.get $i) (call $ds_cnt (local.get $dsid))))
      (local.set $ts  (i64.load (call $ds_rec_ptr (local.get $dsid) (local.get $i))))
      (if (i64.gt_s (local.get $ts) (call $view_e)) (then (br $brk)))
      (local.set $val (f64.load (i32.add (local.get $dp) (i32.shl (local.get $i) (i32.const 3)))))
      (if (f64.ne (local.get $val) (f64.const 0))
        (then
          (local.set $x (call $time_to_x (local.get $ts)))
          (local.set $y (call $price_to_y (local.get $val)))
          (if (i32.ge_s (local.get $px) (i32.const 0))
            (then (call $draw_aa_line (local.get $px) (local.get $py)
                    (local.get $x) (local.get $y) (local.get $r) (local.get $g) (local.get $b))))
          (local.set $px (local.get $x))
          (local.set $py (local.get $y)))
        (else (local.set $px (i32.const -1))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; render all indicators — overlay (SMA/EMA/BB) in main chart, RSI/MACD in sub-panel
  (func $render_indicators
    (local $n i32) (local $i i32) (local $ip i32) (local $type i32)
    (local $cnt i32) (local $out i32) (local $dp i32) (local $col i32)
    (local $dsid i32) (local $s i32) (local $j i32)
    (local $ts i64) (local $val f64) (local $x i32) (local $y i32)
    (local $px i32) (local $py i32) (local $hist_ptr i32)
    (local $zero_y i32) (local $hy i32) (local $hcol i32)
    (local.set $n (call $ind_count))
    (local.set $i (i32.const 0))
    (block $brk (loop $lp
      (br_if $brk (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $ip (call $ind_ptr (local.get $i)))
      (if (i32.load offset=60 (local.get $ip))
        (then
          (local.set $type (i32.load offset=4 (local.get $ip)))
          ;; SMA / EMA only → single line in price space (offset 0)
          (if (i32.le_s (local.get $type) (i32.const 1))
            (then (call $render_ind_line (local.get $i) (i32.const 0))))
          ;; BB: mid(0), upper(1), lower(2) in price space
          (if (i32.eq (local.get $type) (i32.const 2))
            (then
              (call $render_ind_line (local.get $i) (i32.const 0))
              (call $render_ind_line (local.get $i) (i32.const 1))
              (call $render_ind_line (local.get $i) (i32.const 2))))
          ;; RSI: render in indicator sub-panel (if active), else price space
          (if (i32.eq (local.get $type) (i32.const 5))
            (then
              (if (call $ind_ps)
                (then (call $render_ind_panel_line (local.get $i) (i32.const 0)))
                (else (call $render_ind_line (local.get $i) (i32.const 0))))))
          ;; MACD: line + signal in sub-panel; histogram bars in sub-panel
          (if (i32.eq (local.get $type) (i32.const 6))
            (then
              (if (call $ind_ps)
                (then
                  (call $render_ind_panel_line (local.get $i) (i32.const 0))
                  (call $render_ind_panel_line (local.get $i) (i32.const 1))
                  ;; histogram bars (offset 2 = out + cnt*16)
                  (local.set $ip   (call $ind_ptr (local.get $i)))
                  (local.set $out  (i32.load offset=48 (local.get $ip)))
                  (local.set $cnt  (i32.load offset=52 (local.get $ip)))
                  (local.set $dsid (i32.load offset=8  (local.get $ip)))
                  (local.set $col  (i32.load offset=16 (local.get $ip)))
                  (local.set $hist_ptr (i32.add (local.get $out) (i32.shl (i32.mul (local.get $cnt) (i32.const 2)) (i32.const 3))))
                  (local.set $zero_y (call $ind_val_to_py (f64.const 0)))
                  (local.set $s (call $ds_lower_bound (local.get $dsid) (call $view_s)))
                  (local.set $j (local.get $s))
                  (block $hbrk (loop $hlp
                    (br_if $hbrk (i32.ge_s (local.get $j) (call $ds_cnt (local.get $dsid))))
                    (local.set $ts  (i64.load (call $ds_rec_ptr (local.get $dsid) (local.get $j))))
                    (if (i64.gt_s (local.get $ts) (call $view_e)) (then (br $hbrk)))
                    (local.set $val (f64.load (i32.add (local.get $hist_ptr) (i32.shl (local.get $j) (i32.const 3)))))
                    (if (f64.ne (local.get $val) (f64.const 0))
                      (then
                        (local.set $x (call $time_to_x (local.get $ts)))
                        (local.set $hy (call $ind_val_to_py (local.get $val)))
                        (local.set $hcol (select
                          (call $pack_rgba (i32.const 38) (i32.const 166) (i32.const 154) (i32.const 180))
                          (call $pack_rgba (i32.const 239) (i32.const 83) (i32.const 80) (i32.const 180))
                          (f64.ge (local.get $val) (f64.const 0))))
                        (call $draw_rect
                          (i32.sub (local.get $x) (i32.const 1))
                          (call $min_i32 (local.get $hy) (local.get $zero_y))
                          (i32.const 2)
                          (call $max_i32 (i32.const 1)
                            (call $abs_i32 (i32.sub (local.get $hy) (local.get $zero_y))))
                          (local.get $hcol))))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $hlp))))
                (else
                  ;; No sub-panel: draw MACD line and signal in price space
                  (call $render_ind_line (local.get $i) (i32.const 0))
                  (call $render_ind_line (local.get $i) (i32.const 1))))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; render a single indicator line that maps values to the INDICATOR SUB-PANEL
  (func $render_ind_panel_line (param $ii i32) (param $offset_mult i32)
    (local $ip i32) (local $dp i32) (local $cnt i32) (local $col i32)
    (local $dsid i32) (local $s i32)
    (local $r i32) (local $g i32) (local $b i32)
    (local $i i32) (local $ts i64) (local $val f64)
    (local $x i32) (local $y i32) (local $px i32) (local $py i32)
    (local.set $ip  (call $ind_ptr (local.get $ii)))
    (local.set $cnt (i32.load offset=52 (local.get $ip)))
    (if (i32.eqz (local.get $cnt)) (then (return)))
    (local.set $col  (i32.load offset=16 (local.get $ip)))
    (local.set $dsid (i32.load offset=8  (local.get $ip)))
    (local.set $s    (call $ds_lower_bound (local.get $dsid) (call $view_s)))
    (local.set $dp
      (i32.add (i32.load offset=48 (local.get $ip))
               (i32.shl (i32.mul (local.get $offset_mult) (local.get $cnt)) (i32.const 3))))
    (local.set $r (call $ch_r (local.get $col)))
    (local.set $g (call $ch_g (local.get $col)))
    (local.set $b (call $ch_b (local.get $col)))
    (local.set $px (i32.const -1))
    (local.set $i  (local.get $s))
    (block $brk (loop $lp
      (br_if $brk (i32.ge_s (local.get $i) (call $ds_cnt (local.get $dsid))))
      (local.set $ts  (i64.load (call $ds_rec_ptr (local.get $dsid) (local.get $i))))
      (if (i64.gt_s (local.get $ts) (call $view_e)) (then (br $brk)))
      (local.set $val (f64.load (i32.add (local.get $dp) (i32.shl (local.get $i) (i32.const 3)))))
      (if (f64.ne (local.get $val) (f64.const 0))
        (then
          (local.set $x (call $time_to_x (local.get $ts)))
          (local.set $y (call $ind_val_to_py (local.get $val)))
          (if (i32.ge_s (local.get $px) (i32.const 0))
            (then (call $draw_aa_line (local.get $px) (local.get $py)
                    (local.get $x) (local.get $y) (local.get $r) (local.get $g) (local.get $b))))
          (local.set $px (local.get $x))
          (local.set $py (local.get $y)))
        (else (local.set $px (i32.const -1))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))))

  ;; ── crosshair ─────────────────────────────────────────────────────────
  (func $render_crosshair
    (local $x i32) (local $y i32) (local $col i32)
    (local.set $x (i32.load offset=128 (i32.const 0)))
    (local.set $y (i32.load offset=132 (i32.const 0)))
    (if (i32.lt_s (local.get $x) (i32.const 0)) (then (return)))
    ;; semi-transparent white crosshair
    (local.set $col (call $pack_rgba (i32.const 220) (i32.const 220) (i32.const 220) (i32.const 100)))
    (call $draw_hline (call $cx) (i32.add (call $cx) (call $caw)) (local.get $y) (local.get $col))
    (call $draw_vline (local.get $x) (call $cy) (i32.add (call $cy) (call $cah)) (local.get $col)))

  ;; ── hit test ──────────────────────────────────────────────────────────
  (func (export "hit_test") (param $x i32) (param $y i32) (result i32)
    (local $id i32) (local $ts i64) (local $n i32) (local $idx i32)
    (local.set $id (call $active_ds))
    (if (i32.lt_s (local.get $id) (i32.const 0)) (then (return (i32.const -1))))
    (local.set $n (call $ds_cnt (local.get $id)))
    (if (i32.eqz (local.get $n)) (then (return (i32.const -1))))
    ;; bounds check
    (if (i32.or
          (i32.or (i32.lt_s (local.get $x) (call $cx))
                  (i32.ge_s (local.get $x) (i32.add (call $cx) (call $caw))))
          (i32.or (i32.lt_s (local.get $y) (call $cy))
                  (i32.ge_s (local.get $y) (i32.add (call $cy) (call $cah)))))
      (then (return (i32.const -1))))
    (local.set $ts (call $x_to_time (local.get $x)))
    (local.set $idx (call $ds_upper_bound (local.get $id) (local.get $ts)))
    (call $clamp_i32 (local.get $idx) (i32.const 0) (i32.sub (local.get $n) (i32.const 1))))

  ;; ── main render entry point ───────────────────────────────────────────
  (func (export "render_chart")
    (call $render_grid)
    ;; dispatch chart type
    (if (i32.eqz (call $chart_type))
      (then (call $render_candlestick)))
    (if (i32.eq (call $chart_type) (i32.const 1))
      (then (call $render_line)))
    (if (i32.eq (call $chart_type) (i32.const 2))
      (then (call $render_area)))
    (if (i32.eq (call $chart_type) (i32.const 3))
      (then (call $render_ohlc_bar)))
    (if (i32.eq (call $chart_type) (i32.const 4))
      (then (call $render_volume_main)))
    (if (i32.eq (call $chart_type) (i32.const 5))
      (then (call $render_scatter)))
    ;; volume overlay panel (not drawn when standalone volume is the chart type)
    (if (i32.and (call $show_vol)
                 (i32.ne (call $chart_type) (i32.const 4)))
      (then (call $render_volume)))
    ;; indicator sub-panel grid
    (call $render_ind_panel_grid)
    ;; indicators
    (call $render_indicators)
    ;; axis labels
    (call $render_price_labels)
    (call $render_time_labels)
    ;; crosshair on top
    (call $render_crosshair))
)
