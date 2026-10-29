# Math v2 datasets

Run each source command with the shared environment, then aggregate counts:

```sh
build/glyph-venv/bin/python scripts/glyphs/datasets.py mw-symbols
build/glyph-venv/bin/python scripts/glyphs/datasets.py crohme
build/glyph-venv/bin/python scripts/glyphs/datasets.py hwrt
build/glyph-venv/bin/python scripts/glyphs/datasets.py stats
```

The script writes under `ROOT/build/datasets/`. When run from a linked worktree, pass
`--build-dir PATH` and `--math-vocab PATH` for the shared build directory and v2 vocab.
The MathWriting tar is streamed; nested CROHME zip files are read in memory. No source
archive is extracted.

Each record has `src`, `split`, `writer`, `label`, `class`, `strokes`, and `ink_id`.
Stroke points are `[x, y, t]`; source times are kept when present. MathWriting inks
have no writer ID, so `writer` is `null` there. CROHME formula records use the root
writer annotation, falling back to the filename prefix before its last underscore.

The single-label map is the v2 contract map. Symbols that do not linearize to exactly
one of the 65 math labels are omitted and counted in `.pipeline-metadata.json` and
`stats.json`. CROHME also counts held-out source expressions and duplicate isolated
symbols. `stats.json` reports counts by source, split, and model class; it checks class
consistency, split isolation by `ink_id`, and the 3,000,000,000-byte output cap.

MathWriting `symbols.jsonl` references source strokes in `train/`; only its referenced
strokes become symbol records, all in `train`. CROHME formula `Train.zip` is split by
writer: SHA-256 of `20261003:crohme:<writer>`, first eight digest bytes interpreted
big-endian, modulo 10 equal to zero means `valid`. The formula `valid.zip` is emitted
as `test` (TEST-C). Isolated symbols come from their companion ground-truth text files
inside `subTask_symbols/Train.zip` and are train-only. Exact UI links to formula inks
are checked against every formula train/valid UI; symbols linked to writer-held-out
or TEST-C expressions are dropped. The archive README marks the 2014 `trainingSymbols`
folder as generated from a training expression list; its 20 `MfrDB0104` trainingSymbols
UI prefixes and 10 trainingJunk UI prefixes have no matching UI in the selected formula
archives and remain train-only under that provenance. The 2012 and 2013 isolated folders
require exact formula UI links. When a
symbol UI links to a formula, its trace references are ordered by the source formula's
trace order, not the isolated InkML element order (for example, BOTH10003 lists 5,4,6
but its source formula order is 4,5,6). Unlinked 2014 MfrDB samples retain their
traceView order. CROHME traces contain X/Y without a measured time channel; formula
records receive deterministic increasing point ordinals across the full source
expression trace order before symbol groups are selected. Isolated symbol records use
increasing ordinals across that record's restored stroke order.
MathWriting InkML times and HWRT point `time` values are retained as supplied.
Measured CROHME timestamps are also retained verbatim; some source traces have
small adjacent timestamp reversals. Raw records preserve source point order.

HWRT records use the reader in `train.py` and the final writer assignments in
`build/glyph-training/prepare.json`, including its coverage repairs. The split is
copied from that assignment; the provisional split produced by the legacy reader is
ignored. `build/glyph-synth/synthetic.jsonl` is read only because the shared reader
also handles it; synthetic records are not emitted by the `hwrt` command.

Dataset licenses: MathWriting CC BY-NC-SA 4.0, CROHME 2019 CC BY-NC-SA 3.0, and HWRT
ODbL 1.0. The pipeline writes deterministic gzip streams (`mtime=0`, empty gzip
filename) so identical inputs produce identical output bytes.
