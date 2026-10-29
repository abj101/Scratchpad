## Data sources (exact)

| Id | Source | URL | Size | Use |
|---|---|---|---|---|
| MW | MathWriting 2024 | `https://storage.googleapis.com/mathwriting_data/mathwriting-2024.tgz` | 3,096,141,721 B | `symbols/` + `symbols.jsonl` → train. `train/` → LM corpus and harvest (train). `synthetic/` labels → LM corpus only. `valid/` → LM-free validation (harvest). `test/` → unused. |
| CR | CROHME 2019 Task 1+2 | `https://www.cs.rit.edu/~crohme2019/downloads/Task1_and_Task2.zip` | 242,113,077 B | Inner `Task1_onlineRec/MainTask_formula/Train.zip` → train (90%) / validation (10%, by writer). `.../MainTask_formula/valid.zip` → **TEST-C**. `Task1_onlineRec/subTask_symbols/Train.zip` → train. Ignore `Test.zip` (no ground truth) and `Task2_offlineRec`. |
| HW | HWRT raw strokes (already used) | `build/hasy/2015-01-28-data.tar` | existing | Train/validation with the existing writer split. |
| SY | Existing Hershey/Relief synthetic | `build/glyph-synth/synthetic.jsonl` | existing | Top-up only: a class with fewer than 2,000 real training samples gets synthetic samples up to 2,000. |
| CAP | Ayush's captures | `build/glyph-capture` | existing | 325 records for the 65 math labels, split into **CAP-tune** (130, augmentation tuning and early trackpad check) and **CAP-test** (195, test only). Never training data. |

**License decision** (2026-10-04, Ayush): this app is personal and will never be sold. Non-commercial (MathWriting, CC BY-NC-SA) and research-terms (CROHME) data are approved for training, harvest and evaluation. Attribution notices are still kept.

Verified formats:
- **MW** InkML: `<trace>` points are `x y t`, comma-separated. Annotations are `label`,
  `normalizedLabel` (missing under `symbols/`; use `label` there), `splitTagOriginal`,
  `sampleId` and `inkCreationMethod`. There are no writer ids. `symbols.jsonl` lines look like
  `{"sourceSampleId", "strokeIndices": [int], "label": LaTeX}`, where `sourceSampleId` points
  to a `train/` ink. Coordinates are unnormalized, with y increasing downward.
- **CR** InkML: strokes in `<trace>`, symbols in `<traceGroup>` with
  `<annotation type="truth">` plus `<traceView traceDataRef>`, and a `truth` LaTeX annotation
  on the root. Writer is in `<annotation type="writer">` when present; otherwise use the file
  stem's prefix before the last `_`. Agent B must confirm that `valid.zip` carries
  traceGroups. If it doesn't, stop and report to Sol (fallback: hold out 15% of `Train.zip`
  by writer as TEST-C).

Record SHA-256 of both downloads in `build/datasets/SOURCES.json`, along with URL, byte size,
license and download date.
