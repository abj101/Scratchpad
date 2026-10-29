# Items 1–3: validation follow-up

Three Luna subagents at high reasoning prepared the coverage audit, per-label threshold comparison, and centered p-norm logit normalization. See [the audit](selective-validation-audit.md) for the saved F3-second findings.

The new `calibrate_v2.py selective-validation` command uses the existing F3-second checkpoint and CROHME training-pool validation expressions only. It compares the saved failed calibration setting, a newly fitted global threshold, per-label thresholds, and per-label thresholds after logit normalization (`p=2`). Each normalized likelihood gets its own fitted temperature. It reports final substitutions on `<unk>` truths, coverage over all symbols, and coverage over known symbols separately.

Threshold fitting and comparison use alternating expressions sorted by SHA-256 of their IDs. This separates threshold selection from comparison, but the checkpoint and historical baseline already used validation data. Results are exploratory, not an independent release test. The normalized softmax decoder experiment adapts the paper's transform; it does not reproduce its max-normalized-logit uncertainty score. No reject class is trained, no test sets are accessed, and no app model or manifest is exported.

## Human-run command

Allow approximately 5–30 minutes; this is an estimate, not a measured runtime. The agent has not launched this run. Run in the foreground:

```bash
bash /Users/ayush/Developer/Scratchpad/build/orchestration-v2-wave3/run-selective-validation.sh
```

The runner writes `selective-validation.log`, `selective-validation.json`, and `selective-validation.done` under `build/orchestration-v2-wave3/`. The `.done` file contains the exit code, including failures. Tell the agent **done** afterward. It should then read only that marker, the report JSON, and the last 20 log lines before reporting the numerical comparison. No training or additional calibration should start automatically.
