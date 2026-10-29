# Hershey family sources

The bundled `.jhf` family files are from the `hershey-fonts` directory at
[`kamalmostafa/hershey-fonts`](https://github.com/kamalmostafa/hershey-fonts/tree/1356bf2f83d380fcef68c887e88675eb9d445d86/hershey-fonts), pinned to commit
`1356bf2f83d380fcef68c887e88675eb9d445d86`. The complete source use notice is
`hershey.txt`; the app-facing acknowledgement is
`Sources/CanvasKit/Resources/HERSHEY-NOTICE.txt`.

The family files are only used to establish family membership. `synth.py`
matches the exact `(left, right, stroke sequence)` shape from each family file
to the same `charcode` in the decoded `python-hershey` source. Candidate IDs
come from `vocab.json`; composed glyphs use the checked-in complete glyph path
and are never reconstructed from their components.

| Source file | SHA-256 |
|---|---|
| `rowmans.jhf` | `8718fb129c0f6bce89c84fe41bc467e39534d215a6f7c3220cc5789a8a7d8618` |
| `timesr.jhf` | `c454a5ed471aa33c1aac8c5b21c2d343e828805af2b48eebba20c46f492d9457` |
| `timesi.jhf` | `66cd7ca5c402d5609de083b166f704d89025619f2dabe42f3d13be95b261414b` |
| `timesib.jhf` | `e2cf4755a2b2706b21812060f8ecc7462c1e79f0c5147526bea3c00ed4bb1867` |
| `scripts.jhf` | `6b391b2ea3a0771cf18caff0ed111db3d05681fa586d423a740cc0b2b155a873` |
| `scriptc.jhf` | `747f9384b0adbec3f6826cc374727adb262c6a96e2a758a2472d11291b7104c7` |
| `greeks.jhf` | `309298debb0e472047f8329d31f849b14a98108a706d0f4f684e40d1eb023a76` |
| `greekc.jhf` | `e1eae76922db931d47475b868ff1cf19bf083601925272a541f914cc71004fb4` |

The decoded glyph records are read from
`https://raw.githubusercontent.com/scruss/python-hershey/master/hershey-occidental.json`.
Pass its local path with `--hershey-source` when it is not available at
`build/hershey/official.json`.
