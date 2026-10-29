# Shared glyph raster spec

`raster.py` and `GlyphRaster.rasterize(_:)` implement the same raster from raw stroke points. Training images and app input use this renderer; HASY PNGs are reference material only.

## Output and normalization

- Output is 32×32 grayscale, row-major, y-down: `0` is black and `255` is white. Empty input produces 1,024 white bytes. There is no antialiasing.
- Normalize all nonempty strokes together, preserving aspect ratio. The longest coordinate span maps to a 26 px centerline span centered at 16 px. Its extrema are at 3 and 29; the shorter axis is centered. This leaves a 2 px white border after drawing the 2 px stroke. A single point, or a set of coincident points, maps to `(16,16)`.
- Coordinates must be finite and within ±200,000 world units. Invalid input produces a blank image. Empty paths are ignored. Stroke color, width, and time are ignored.

## Integer normalization and raster rules

Both implementations convert coordinates relative to the global minimum into Q16 integers (65,536 units per input unit), rounding to nearest with ties away from zero. Let `sx`, `sy` be the maximum relative Q16 coordinates and `span=max(sx,sy)`. For a nonzero span, a coordinate `x` maps to Q8 pixels as:

```text
xQ8 = 16*256 + round_away((2*x - sx) * (13*256) / span)
```

Use the corresponding `y` expression. `round_away` rounds an integer ratio to nearest, ties away from zero. A zero span maps every point to `(16*256,16*256)`.

Pixels are sampled at Q8 centers `(i*256+128, j*256+128)`. Each adjacent point pair covers a 2 px wide capsule: a pixel is black when its center is at most 1 px from the segment. Test that with integer squared distances: use endpoint distance when the projection is before or after the segment, and otherwise test `cross² <= 256² * segmentLength²`. The union gives round caps and joins. One-point and zero-length strokes use the same test as a radius-1 disk. Both APIs emit identical binary bytes.

## Vocabulary

`Sources/CanvasKit/Resources/vocab.json` is the class/group/source-ID authority.
The rasterizer accepts only stroke geometry and has no label-specific mapping.
The round group includes `0`, `o`, `O`, `∘`, `°`, `.`, and `·`: after fit-to-box
normalization, a compact loop can represent a dot, a small circle, or a degree mark.
The raster keeps points, loops, and scribbles as drawn. Synthetic dot training samples
cover all three shapes by deriving them from bundled Hershey `°` geometry (source ID 718,
with its Hershey notice and license retained), and map them to this shared group so
equivalent loops never get conflicting targets. A later symbol resolver uses the original
symbol size, vertical position, and input mode to choose the member; neither captured test
strokes nor app predictions receive label-based preprocessing.
