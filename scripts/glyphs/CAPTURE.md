# Capture the held-out glyph test set

R1–R3 and the R4 developer tool are built. Training waits for Ayush's samples.
The vocabulary contains 158 labels: five samples each, 790 total.

1. Quit any older running Scratchpad, then launch the Debug build:
   ```sh
   open /Users/ayush/Developer/Scratchpad/build/dd/Build/Products/Debug/Scratchpad.app
   ```
2. Open a note. Finish or discard pending writing and deselect objects. Choose
   **Debug → Capture Glyph Samples**. A refused start beeps; capture does not flush
   pending writing. The pill shows the label, its Unicode codepoint, sample number,
   and overall progress.
3. Write one complete sample of the displayed glyph, using your usual trackpad pen
   key (Space by default). Use your natural handwriting, size and vertical position.
   All strokes of a glyph belong to that sample; idle time does not save it.
4. Release the pen key, or turn it off if using toggle activation. Press **⌘⌥S**
   (**Debug → Save Glyph Sample**). Repeat five times for each label; the prompt advances
   automatically. A save error keeps the draft and label so you can retry.
5. **Delete** or **←** clears only the current draft. With an empty draft, **⌘⌥Z**
   (**Debug → Redo Last Glyph Sample**) deletes the latest save from this active session
   so you can replace it.
6. **Escape** or **Debug → Cancel Glyph Capture** pauses capture and discards the unsaved
   draft. Saved files remain. Start capture again to resume from the first label below
   five samples. Your previous writing context and settings are restored on exit.
7. Capture exits automatically after the last sample. Report back: **“Capture complete”**,
   along with any glyph you could not write or tool issue. R5–R7 resume then.

Files: `/Users/ayush/Developer/Scratchpad/build/glyph-capture/*.json`.
They preserve original pre-tidy points, timestamps, cell geometry and stroke style.
Every sample is marked `writer: ayush`, `split: test`; keep this set held out from training.
The command and capture implementation are absent from Release builds.
