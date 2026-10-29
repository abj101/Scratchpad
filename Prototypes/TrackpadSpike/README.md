# Trackpad Spike (Phase 0)

## Purpose

Go/no-go test of trackpad drawing for a Mac notes app. This prototype investigates whether finger handwriting on a trackpad can be made legible enough to be useful as an input method.

## How to Run

```bash
./run.sh
```

This builds and launches the app in release mode.

## Controls

- **`1`** Relative Pen mode (cursor moves normally; hold/toggle pen key to draw)
- **`2`** Tablet mode (trackpad maps absolutely to the outlined region; cursor is frozen and hidden)
- **`Esc`** Leave Tablet mode / lift pen (safety)
- **`K`** Cycle pen key: Space → Option → Fn
- **`T`** Toggle activation style: Hold ↔ Toggle
- **`S`** Toggle smoothing (One-Euro filter) on/off
- **`R`** Show raw input overlay (faint red) under smoothed strokes
- **`[`** / **`]`** Smoothing min-cutoff down/up
- **`;`** / **`'`** Smoothing beta down/up
- **`-`** / **`=`** Stroke width down/up
- **`Z`** Undo last stroke
- **`C`** Clear all strokes

### HUD (Top-Left)

The on-screen display shows:
- Current mode (Relative Pen / Tablet)
- Pen key + state (e.g., "Space: Up")
- Touch count
- Touch event rate (Hz)
- Mouse-move rate (Hz)
- Events received while pen key held
- Milliseconds since last input event

## Test Checklist

### 1. Key-Hold Suppression

In **Relative Pen mode**, hold Space and move a finger. Does the cursor/stroke keep moving, or freeze for ~0.5–1s? Watch "events while key held" and "ms since last input". Repeat with Option and Fn.

Same test in **Tablet mode** (touch events vs mouse events may be filtered differently).

### 2. Tap-to-Click Safety

In **Tablet mode**, tap once without dragging. Does it create stray marks or move anything? Should be a no-op.

### 3. Multi-Touch Behavior

In **Tablet mode**, press two fingers down. Does the stroke suspend? Should not create artifacts.

### 4. Legibility Test

Write "hello world" in each mode, smoothing on vs off. Tune the smoothing parameters:
- `[ ]` for min-cutoff
- `; '` for beta

Record which settings feel best for legibility.

### 5. Touch Rate & Jag Analysis

Note the touch rate (Hz) displayed in the HUD. Do diagonal and curved strokes look jagged, or smooth? Correlate with frame rate and parameter tuning.

### 6. Go/No-Go Verdict

Is finger handwriting legible enough to be useful?

## Results Template

After testing, fill in the following:

```
Mac Model: _______________
macOS Version: _______________

Key-Hold Suppression Results:
  Space: _______________
  Option: _______________
  Fn: _______________

Best Mode: _______________
Best Smoothing Parameters:
  Min-Cutoff: _______________
  Beta: _______________

Touch Rate (Hz): _______________

Legibility Verdict (go/no-go): _______________

Notes:
_______________________________________________________________________________
_______________________________________________________________________________
```
