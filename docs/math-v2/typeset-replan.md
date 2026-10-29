# Editable formatted equations

This replaces the unapplied custom CoreText/STIX typesetting proposal.

Math stays inside the Scribe lifecycle and inserts inline equation attachments at the regular text target in canvas and document notes. Original handwriting geometry is used for recognition, segmentation, decoder context, and script-role detection. Accepted math adds no output ink.

MathLive 0.111.0, fonts, and license notices are bundled locally. One active WKWebView mathfield supplies structured insertion, selection, navigation, and editing. The automatic virtual keyboard is disabled. Handwriting bypasses prose capitalization, autocorrect, word segmentation, and sentence polish.

Each NSTextAttachment stores its equation ID, authoritative LaTeX source, canonical font size, and a derived cached PDF preview with layout metrics. Source changes save immediately. Preview generation is asynchronous, rejects stale results, and does not add undo steps; source remains available if rendering fails. Equations exceeding the text width fit proportionally.

Handwriting commits and decoder revisions form one native note undo operation. Keyboard edits use the same undo history. Recent handwritten symbols track MathLive selection ranges; external caret movement or keyboard edits invalidate overlapping revision history.

Uncertain symbols remain as original ink in the input panel, with an unreadable-symbol message and advancement paused. Retry, keyboard correction, or Delete resolves them. Accepted source remains saved. Enter finishes and inserts a newline; switching to prose finishes at the same target and preserves unresolved input for a return to math.

Attachment archiving, reopening, duplication, rich clipboard, plain-text LaTeX copy, source Find, and layout conversion preserve equation content. The note format version increases and secure decoding explicitly permits equation attachments. Existing saved ink is read unchanged.

Validation covers recognition confidence gates and function names; fractions, scripts, Greek symbols and revisions; keyboard/handwriting editing and undo; uncertainty and mode switching; preview races and failure; save/load, clipboard, Find, conversion, and offline rendering across widths and zoom levels.

References: [MathLive integration](https://mathlive.io/mathfield/guides/integration/), [MathLive API](https://mathlive.io/mathfield/api/).
