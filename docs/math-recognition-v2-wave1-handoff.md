# Fresh Sol handoff: finish wave 1 only

You are taking over orchestration from `/root` because Ayush requested a fresh
context after the implementation subagents finish. Use Sol 6.1 Medium. Work in
`/Users/ayush/Developer/Scratchpad`; the outgoing orchestrator will stop editing
before dispatch. Do not create a new branch or reset this checkout.

## User instructions

- Execute **wave 1 only** of `docs/math-recognition-v2-plan.md`.
- Ponytail **ultra**: `/Users/ayush/.agents/skills/ponytail/SKILL.md`.
- Stop on any actual blocker and report it for Claude to decide. Routine coding
  or build-cache fixes are not unresolved decisions. Do not invent fallback data.
- Be efficient and cheap. Sol 6.1 Medium and Luna Max subagents are authorized;
  the existing implementations should only need review/integration/checks.
- Never push. Commit locally once the wave is verified, with final trailer
  `Co-Authored-By: Codex <noreply@openai.com>`.
- Preserve captures, source datasets, models and training reports. Remove only
  verified duplicate/reproducible scratch artifacts after integration.
- No `.codegraph/` currently exists. If one exists at takeover, use CodeGraph
  before searching/reading code. Read the current plan and `running.md` first.

## Checkout and completed work

Branch `codex/math-recognition-v2`, latest commit `00fcaab`, baseline `8dadc1a`.
The current dirty checkout contains verified A/D changes and plan/log updates;
keep them. The user updated the allocation contract after the original blocker.
It now specifies Hamilton allocation above a two-sample floor, zero-length
handling, precise double arithmetic, exact endpoints, and 12 parity fixtures.
The old blocker document is marked resolved.

Wave 0 complete: both downloads are verified under ignored `build/datasets/`,
provenance in `SOURCES.json`, requirements pinned. Original root independently
checked both sizes and SHA-256. MathWriting was never extracted. About 1.9 GB of
stale caches were removed; A/D isolated worktrees were subsequently deleted only
after their owned files were verified byte-identical to integrated files.

A integrated:

- `MathVocabulary.swift`, `Resources/math-vocab.json` (65 labels/59 classes),
  soft resolver in `SymbolResolver.swift`, `scripts/glyphs/resolver.py`, tests
  and `Fixtures/resolver/`.
- All Hershey keys preserved; lexical class order and memberships checked.
- 20 Swift/Python fixtures within 1e-9. Missing baseline **or median** gives
  neutral weights, even if a fixture supplies a cell height. This honors the
  contract's explicit final neutral-fallback clause. Removed class/q rejected.
- Existing hard resolver and CanvasView unchanged.
- Root checks: Python self-check, 12 focused Swift tests, all 702 Swift tests
  (zero failures, one benchmark skip), Debug app build passed.

D integrated:

- `GlyphSequence.swift`, `scripts/glyphs/sequence.py`, tests and
  `Fixtures/sequence/`.
- API `GlyphSequence.encode(_:) -> Features?`, Float points `[128][4]`, counts.
  Empty/invalid input returns nil; first 64 nonempty strokes kept. Worked
  Hamilton allocations, duplicate removal, endpoints and pre-resampling bbox.
- 12 fixtures within 1e-5 with identical allocations, four focused Swift tests.
  Root's intermediate all-698 suite and Debug build passed before A.
- Globals deliberately remain for wave 2; do not implement classifier runtime.

Main `Package.swift` already registers math-vocab, sequence and resolver. Logs:
`build/orchestration-v2/root-{A,D}-{tests,full-tests,debug}.log`.

## C: Python/corpus/model handback

Worktree `/Users/ayush/Developer/math-v2-worktrees/language`.
Agent `/root/language` owns only:

- `scripts/glyphs/linearize.py`, `grammar.py`, `lm.py`
- `Sources/CanvasKit/Resources/MathLM.json`
- `Tests/CanvasKitTests/Fixtures/lm/linearize-goldens.json`, `lm-queries.json`

Deliver the two real fixture files only; scratch `linearize-candidates.json`
belongs in ignored build space, not shipped test resources.

The linearizer has 40 handwritten expected results from actual MW train labels.
Fraction parentheses are all-or-both: wrap both sides unless both have exactly
one label. Corpus readers strip surrounding TeX math wrappers and read only root
annotations, prioritizing normalizedLabel. No MW test or CAP was used.

MKN order 4, 67 vocabulary entries, no end token. Counts are true suffix ngrams,
start ID is `<s>` (not digit 0), lower-order counts are distinct predecessors.
Order 3/4 pruning count 23 fits the cap. Context-only start rows retain their
actual fallback probability and backoff weight; omitting them had produced
non-normalized start distributions and was fixed.

Final artifact:

- 2,922,626 bytes, SHA-256
  `d2ea03470117685e7ce7a06bf159ad11755f28e747ed9dfbb026a5bdeed5aaa2`.
- Ngrams by order: 67 / 4,061 / 20,748 / 30,815.
- Training inputs: 93,538 MW train + 140,110 MW synthetic + 6,878 CROHME formula
  train + 120,263 seeded grammar expressions. No validation training.
- All MW validation: perplexity **13.00820699810784**, 15,674 expressions,
  178,512 labels. Includes 11,264 expressions with >10% unknown tokens.
- Filtered ≤10% unknown subset: 10.928282213181056, 4,410 expressions,
  51,021 labels. Do not present this filtered result as overall perplexity.
- Full `2x+4` log10 score −4.827934489198348; `2·+4` −8.262565526184806.
  The contract check is the **whole expression with right context**. Isolated
  `x|2` slightly trails `·|2`; this is transparently reported, not a reason to
  tune the model or demand an unrequested one-step dominance assertion.

Outgoing root independently regenerated the model AND 50 query fixtures:
byte-identical. Report/log in `build/orchestration-v2/root-C-training-report.json`
and `root-C-training.log`. Regeneration scratch in `lm-recheck/` may be removed
once its evidence is logged. Root independently checked 304 contexts including
one/two/three start tokens: max probability-mass error 2.22e-16.

Fast checks: `python scripts/glyphs/linearize.py`, `grammar.py`,
`lm.py --self-check`. `lm.py --perplexity-only` loads the existing model and
streams all nonempty MW valid expressions without any model writes. Use the
shared `build/glyph-venv/bin/python` for every v2 script.

## C: Swift handback

Worktree `/Users/ayush/Developer/math-v2-worktrees/lm-runtime`.
Agent `/root/vocabulary` finished this disjoint helper task. Owns exactly:

- `Sources/CanvasKit/MathLanguageModel.swift`
- `Tests/CanvasKitTests/MathLanguageModelTests.swift`

API: public value type, `bundled`, `load(from:)`,
`logProb(_ word: String, context: [String]) -> Double` (log10).
Standard backoff, context last three tokens, unknown words/context tokens map
to `<unk>`. Three tests pass, including fixed numeric backoff, unknown/truncation,
50 Python queries within 1e-9 and whole-expression x-vs-dot.
Temporary resource copies were removed and Package.swift restored.

Integration needs `.copy("Resources/MathLM.json")` and test
`.copy("Fixtures/lm")` in main Package.swift. A known macOS SwiftPM test issue
embeds stale resource bundles; `swift package clean` in the relevant checkout
fixed bundled-loader nil. Clean once after registration if necessary.

## B handback / final takeover status

Worktree `/Users/ayush/Developer/math-v2-worktrees/pipeline`.
Agent `/root/data_setup` owns only `scripts/glyphs/datasets.py` and `DATA.md`.
First full source run and stats are complete. Final evidence is appended below.

Important reviewed source details:

- MW `symbols.jsonl` is first (offset 512), before train inks; one-pass join works.
  All 6,423 metadata index lists are in written order. Only train sources used.
- CROHME formula Train has 9,993 inks, TEST-C valid has 986 with traceGroups.
  Isolated labels are in companion GT text files, not empty InkML annotations.
- Exact UI linkage filters all held-out expressions; archive README explicitly
  marks unmatched 20 MfrDB trainingSymbols as train-only. Preserve source namespace.
- Linked isolated traces use original formula order (BOTH10003: 4,5,6 despite
  isolated XML order 5,4,6). Formula derived timestamps are assigned once across
  the complete expression before extracting groups; isolated times are local
  ordinal ticks. Actual source timestamps are retained. These are not measured ms.
- HWRT reuses train.py's reader but accepted repaired writer assignments from
  `build/glyph-training/prepare.json` (332 train/93 valid writers). Filter math
  labels before requiring writer membership. Canonical Unicode labels accepted.
- Gzip mtime 0 and empty filename; atomic outputs. Main defaults use ROOT/build;
  worktree commands supply shared build/vocab explicitly. No git path autodetection.

Outgoing root requested **one full data pass from B**. You perform the second
independent pass, in an ignored scratch build directory with explicit source
archive/HWRT/prepare/synthetic paths, then compare gzip bytes/hash and stats.
Do not do a gratuitous third pass. Verify all schema fields, classes, points,
writer splits, source-expression exclusion and no ink ID spans splits. Derived
data ≤3 GB; total new disk use <8 GB. Do not evaluate models on TEST-C or CAP.

## Finish procedure

1. Read all final handbacks below and inspect their actual diffs/files. If B has
   an actual blocker, stop: do not proceed until Ayush/Claude decides.
2. Integrate C and B owned files into main, preserving dirty A/D and user plan edits.
3. Register LM resource/fixtures. Rerun Python checks, all 40 linearizer cases,
   all 50 Swift parity queries and appropriate focused Swift tests yourself.
4. Independently verify all-valid perplexity without modifying model; preserve
   immutable test sets. Perform B's second deterministic run and integrity checks.
5. Run full `swift test` (expected 705 tests if three C tests remain) and Debug:
   `xcodebuild -project Scratchpad.xcodeproj -scheme Scratchpad -configuration Debug
   -derivedDataPath build/math-v2-dd CODE_SIGNING_ALLOWED=NO build`.
   Log commands under `build/orchestration-v2/`. Release is not required until wave 2.
6. Update plan A–D statuses and running.md with actual evidence/metrics. Mark wave 1
   complete only when all requirements pass. Commit locally with attribution.
7. Verify copied handback files byte-identical before removing temporary worktrees
   and duplicate caches. Preserve original archives, captures, training artifacts.
8. Return concise outcome, checks, commit and limitations. **Do not start wave 2.**

All subagents must be finished before exclusive orchestration transfers to you.

## Final C handback

Python agent and Swift helper are finished. Python syntax checks, LM fixed-corpus
and probability-mass self-checks, 46 linearizer tests, and grammar self-check pass.
Exactly 40 distinct real MathWriting sources are enforced for the handwritten
goldens. No candidate scratch fixture remains. Final cleanup removed a duplicate
stats key and duplicate self-check execution; model bytes remain unchanged.

Training command (run from the language worktree):
`/Users/ayush/Developer/Scratchpad/build/glyph-venv/bin/python scripts/glyphs/lm.py --mathwriting /Users/ayush/Developer/Scratchpad/build/datasets/mathwriting-2024.tgz --crohme /Users/ayush/Developer/Scratchpad/build/datasets/Task1_and_Task2.zip`.

Validation-only command adds
`--output Sources/CanvasKit/Resources/MathLM.json --perplexity-only` and omits
`--crohme`; it leaves the artifact unchanged. All-valid perplexity is
13.00820699810784 (15,674 sequences, 178,512 labels). The <=10% unknown subset
is 10.928282213181056 (4,410 sequences, 51,021 labels); 11,264 sequences exceed
that unknown threshold. Model SHA and full-path comparisons above remain final.

## Final B handback

All source commands and stats completed; **no actual blockers**. Exactly one full
pass was run. Stats passed class-ID consistency and no ink ID across splits.
Report: `/Users/ayush/Developer/Scratchpad/build/datasets/stats.json`.
Drop/provenance metadata:
`/Users/ayush/Developer/Scratchpad/build/datasets/.pipeline-metadata.json`.
These contain the exact per-file SHA-256 hashes for the independent second pass.

Retained 209,023 records: MW train 2,014; CROHME train 161,808, writer-valid 8,984,
TEST-C 9,169; HWRT train 26,306, valid 742. Drops: MW unmapped 4,409; CROHME
unmapped 99,847, held-out source-expression linkage 8,919, empty strokes 2;
HWRT unmapped 141,185. Gzip outputs total 64,930,469 bytes (64,969,593 including
metadata and stats), below the 3 GB limit. No model evaluation used TEST-C.

B ran from the pipeline worktree using the shared Python above, script
`scripts/glyphs/datasets.py`, subcommands `mw-symbols`, `crohme`, `hwrt`, then
`stats`, each with `--build-dir /Users/ayush/Developer/Scratchpad/build`
and `--math-vocab /Users/ayush/Developer/Scratchpad/Sources/CanvasKit/Resources/math-vocab.json`.
All B agents are now finished. See the script CLI for explicit source options
when running into a separate scratch build directory.

Takeover owns remaining C/B integration, independent checks, documentation,
local commit, and verified scratch cleanup. Outgoing root has stopped editing.

## Takeover completion

Wave 1 A–D integrated and independently verified on 2026-10-03. All 705 Swift
tests pass (one expected benchmark skip); Debug app build succeeds. Second B
pass matches every gzip file and both reports byte-for-byte. All 209,023 records
pass schema/finite-point/class/writer/expression-exclusion/ink-ID audit. All-valid
perplexity is independently confirmed at 13.00820699810784; model SHA unchanged.
All 40 goldens were independently matched to MW train root labels. Evidence:
`build/orchestration-v2/takeover-*`. No wave 2, test-set model evaluation or push.
