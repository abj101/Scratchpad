(() => {
  const mf = new MathfieldElement();
  mf.id = 'mf';
  const bridge = window.webkit?.messageHandlers?.mathlive;
  const history = new Map();
  // Letters written as a root's index: id -> the root atom's offset, so a later
  // revision rewrites the index in place instead of replacing the whole radical.
  const rootIndexes = new Map();
  let loaded = false;
  let applying = false;
  let fitting = true;
  let lastSize = '';
  // The widest the native frame can grow; fit only past it, not past the frame's current width.
  let maxWidth = null;
  const placeholder = '\\placeholder{}';
  const fractionSource = numerator => `\\frac{${numerator || placeholder}}{${placeholder}}`;
  // Structured constructs with slots of their own. MathLive focuses the first
  // placeholder on insert: the lower limit for the operators, the radicand for a root.
  // `\limits` forces the operator's limits above and below (an integral would place
  // them beside by default) and round-trips through MathLive's serializer.
  const structureSource = {
    sum: `\\sum\\limits_{${placeholder}}^{${placeholder}}`,
    int: `\\int\\limits_{${placeholder}}^{${placeholder}}`,
    lim: `\\lim_{${placeholder}\\to${placeholder}}`,
    sqrt: `\\sqrt{${placeholder}}`,
  };
  const structureCommands = { sum: ['\\sum'], int: ['\\int'], lim: ['\\lim'], sqrt: ['\\sqrt'], root: ['\\sqrt'] };
  let beforeInput = null;
  let scriptStack = []; // open script levels at the caret, innermost last
  // Openers that materialize their own closer. An absolute-value bar closes with a bar.
  const closers = {'(':')', '[':']', '\\{':'\\}', '|':'|'};
  let autoClosed = 0; // auto-inserted closers still ahead of the caret; arrows/clicks reset it
  // The range a unit delete put up (a filled operator waiting for its second press). The
  // field's own key handling only deletes a *native* selection, so a range set from script
  // has to be taken by the same key handler that raised it.
  let unitSelection = null;
  let resolveReady;
  const readyPromise = new Promise(resolve => { resolveReady = resolve; });
  const send = (kind, value) => bridge?.postMessage({kind, ...value});
  const selection = () => mf.selection?.ranges?.[0] ?? [mf.position, mf.position];
  const sendSelection = external => send('selection', {ranges: mf.selection?.ranges ?? [], external});
  // An empty slot is a *selected* placeholder: MathLive paints a selection box there
  // but no caret, so the insertion point seems to vanish after advancing into a slot
  // (and returns once the first symbol fills it). Flag the focused slot so the
  // injected shadow style can draw a caret on that box.
  function atPlaceholderIndex(index) {
    try {
      const info = mf.getElementInfo(index);
      return typeof info?.latex === 'string' && info.latex.startsWith('\\placeholder');
    } catch { return false; }
  }
  // A focused empty slot is a one-atom selection of its placeholder, not text the user chose.
  function placeholderSelected() {
    const [a, b] = selection();
    return b - a === 1 && atPlaceholderIndex(b);
  }
  function slotCaretActive() {
    const [a, b] = selection();
    if (b - a > 1) return false; // a real multi-atom selection, not a single slot
    return atPlaceholderIndex(a) || atPlaceholderIndex(b) || atPlaceholderIndex(mf.position);
  }
  // MathLive can render more than one caret for a single selection: an operator with side
  // scripts (`\int_0^1`) puts one inside its group *and* one inside the base, so two bars stand
  // on the field and blink out of step. Keep the first — the one MathLive itself reads for
  // caret geometry — and hide the rest by class. Nothing is ever removed: a node deleted from
  // the render that just added it is one MathLive still owns, and it re-adds it at its old
  // position instead of the new one, which is how a small caret could be left standing in a
  // script after the real one moved on.
  const caretSelector = '.ML__caret, .ML__text-caret, .ML__latex-caret';
  function dedupeCarets() {
    const root = mf.shadowRoot;
    if (!root) return;
    const carets = root.querySelectorAll(caretSelector);
    for (let i = 0; i < carets.length; i++) carets[i].classList.toggle('ml-single-caret', i === 0);
  }
  // The caret chrome has two states: `.ml-slot-caret` while a focused slot is the caret (its
  // bar is the caret), and `.ml-selecting` while a real, multi-atom selection is painted.
  function updateSlotCaret() {
    const [a, b] = selection();
    const slot = slotCaretActive();
    mf.classList.toggle('ml-slot-caret', slot);
    mf.classList.toggle('ml-selecting', b > a && !slot);
    dedupeCarets();
  }
  // MathLive only resolves points that land on an atom: a click in the whitespace between
  // two symbols misses every atom and leaves the caret where it was, so placing the caret
  // seemed to work only on the glyphs themselves. Search outward from the click for the
  // nearest position the field can resolve, so any click inside the box moves the caret.
  function offsetNearPoint(x, y) {
    let offset = mf.getOffsetFromPoint(x, y);
    if (offset >= 0) return offset;
    const box = mf.getBoundingClientRect();
    if (!(box.width > 0) || !(box.height > 0)) return -1;
    const cx = Math.min(Math.max(x, box.left), box.right);
    const cy = Math.min(Math.max(y, box.top + box.height * 0.15), box.bottom - box.height * 0.15);
    const limit = Math.ceil(box.width) + 2;
    for (let d = 1; d <= limit; d++) {
      for (const probe of [cx + d, cx - d]) {
        if (probe < box.left || probe > box.right) continue;
        offset = mf.getOffsetFromPoint(probe, cy);
        if (offset >= 0) return offset;
      }
    }
    return -1;
  }
  function changed(origin) { send('change', {latex: mf.value, origin}); }
  function invalidateOverlaps(a, b) {
    for (const [id, range] of history) {
      if ((a !== b && a < range[1] && b > range[0]) || (a === b && a >= range[0] && a <= range[1])) {
        history.delete(id); rootIndexes.delete(id);
      }
    }
  }
  function shiftAfter(end, delta) {
    for (const [id, range] of history) if (range[0] >= end) history.set(id, [range[0] + delta, range[1] + delta]);
  }
  // Where the math itself starts inside the field's own box, in text points. The host draws
  // its static preview at its own padding around the same markup, so it needs this to put the
  // live math exactly where the preview had it instead of a point or two off. Measured with
  // the fit transform off (`getBoundingClientRect` would report the scaled offset otherwise).
  let contentInset = {left: 0, top: 0};
  function measureContentInset() {
    const inner = mf.shadowRoot?.querySelector('.ML__latex');
    if (!inner) return;
    const box = mf.getBoundingClientRect(), math = inner.getBoundingClientRect();
    contentInset = {left: Math.max(0, math.left - box.left), top: Math.max(0, math.top - box.top)};
  }
  function applyFit() {
    if (!fitting || !mf.isConnected) return;
    mf.style.transform='none';
    measureContentInset();
    const natural=Math.max(1,mf.scrollWidth||mf.getBoundingClientRect().width);
    // The host measures the room left on the line and sets it before the first layout.
    // Until it does, shrink nothing: the field still sits in its provisional frame, so
    // fitting to that tiny viewport would scale the whole expression down and snap it
    // back the moment the real width arrives (the squish seen when an equation opens).
    const available = maxWidth == null ? Infinity : Math.max(1, maxWidth);
    window.scrollTo(0,0);
    mf.scrollLeft=0;
    const content=mf.shadowRoot?.querySelector('[part=content]');
    if (content) content.scrollLeft=0;
    const scale=available === Infinity ? 1 : Math.min(1,available/natural);
    if (scale<1) { mf.style.transformOrigin='left top'; mf.style.transform=`scale(${scale})`; document.body.style.height=`${mf.offsetHeight*scale}px`; }
    else document.body.style.height='';
    const size = `${natural}:${mf.offsetHeight}:${scale}`;
    if (size !== lastSize) { lastSize=size; send('size', {width:natural, height:mf.offsetHeight, scale, ...contentInset}); }
  }
  mf.addEventListener('mount', () => {
    mf.mathVirtualKeyboardPolicy='manual';
    // Native CanvasView owns viewport following; MathLive must not pan its
    // max-content web document each time the caret advances.
    mf.onScrollIntoView=() => {};
    // Selection and caret styles. The accent fill and the white text belong to a *real*
    // selection, which the host flags as `.ml-selecting` (see `updateSlotCaret`); MathLive
    // paints a selection box for other things too — a focused placeholder, or a box left
    // standing by a re-render — and painting those with the selection color drew the glyph
    // inside white on white, the top half of a lone integral. The accent still has to be
    // painted by the host rather than MathLive, because MathLive only paints `.ML__selection`
    // while the field has focus, and a selection made through the native ⌘A would then go
    // unhighlighted. The doubled `.ML__selection` class outranks MathLive's own
    // `:host(:focus) .ML__selection` rule regardless of order.
    //
    // A focused empty slot is a *selected placeholder*: MathLive fills its box with the
    // accent color and tints the placeholder glyph white. For a slot we want the light-gray
    // fill-in box instead, with the same thin blinking caret the rest of the field uses. So
    // when `.ml-slot-caret` is on the host: keep the placeholder gray (no white outline over
    // the caret), drop the accent fill, and draw the caret as a bar on the box's `::after` so
    // only the bar blinks.
    const slotStyle = document.createElement('style');
    slotStyle.textContent = `
:host .ML__selection.ML__selection { background: transparent !important; color: inherit; }
:host(.ml-selecting) .ML__selection.ML__selection { background: var(--selection-background-color, hsl(212, 70%, 55%)) !important; color: var(--selection-color, #fff); }
:host(.ml-slot-caret) .ML__container { --_selection-color: #bdbdbd; --_selection-background-color: transparent; }
/* MathLive paints one bar per caret through its ::after, and an operator with side scripts
   gets a pair — one in the group, one in the base, blinking out of step. Only the first is
   MathLive's own idea of the caret, so the rest are hidden by class; while a focused slot is
   the caret, its bar replaces every one of them. Hiding the element would not do it: the
   ::after sets visibility: visible itself. */
:host .ML__caret:not(.ml-single-caret)::after,
:host .ML__text-caret:not(.ml-single-caret)::after,
:host .ML__latex-caret:not(.ml-single-caret)::after,
:host(.ml-slot-caret) .ML__caret::after,
:host(.ml-slot-caret) .ML__text-caret::after,
:host(.ml-slot-caret) .ML__latex-caret::after { visibility: hidden !important; }
:host(.ml-slot-caret) .ML__selection.ML__selection::after {
  content: ''; position: absolute; left: 0; top: 15%; height: 70%;
  width: clamp(2px, 0.08em, 10px); border-radius: 1px;
  background: var(--caret-color, #2878d0);
  animation: ML__caret-blink 1.05s step-end infinite;
}`;
    mf.shadowRoot.appendChild(slotStyle);
    // MathLive renders asynchronously, so a caret it adds after `updateSlotCaret` ran still
    // has to be folded back into one.
    new MutationObserver(dedupeCarets).observe(mf.shadowRoot, {childList: true, subtree: true});
    mf.resetUndo(); loaded = true; resolveReady(); send('ready', {latex:mf.value});
  }, {once:true});
  document.getElementById('field-container').appendChild(mf);
  mf.addEventListener('beforeinput', event => {
    if (event.inputType === 'historyUndo' || event.inputType === 'historyRedo') {
      event.preventDefault(); send(event.inputType === 'historyUndo' ? 'undo' : 'redo', {}); return;
    }
    if (applying) return;
    scriptStack=[];
    const [a,b] = selection(); beforeInput = {a,b,last:mf.lastOffset};
    invalidateOverlaps(a,b);
  });
  mf.addEventListener('input', () => {
    if (applying) { beforeInput = null; return; }
    if (beforeInput) {
      const {a,b,last} = beforeInput; beforeInput = null;
      shiftAfter(b, mf.lastOffset - last);
    }
    changed('keyboard'); mf.resetUndo(); applyFit(); updateSlotCaret();
  });
  // MathLive can dispatch programmatic selection changes after a batch returns.
  // Only user navigation invalidates recognition, never those deferred events.
  function exitScripts() { while (scriptStack.pop()) mf.executeCommand('moveAfterParent'); }
  function userSelection() { history.clear(); rootIndexes.clear(); scriptStack=[]; autoClosed=0; sendSelection(true); }
  mf.addEventListener('pointerdown', userSelection);
  mf.addEventListener('keydown', userSelection);
  mf.addEventListener('selection-change', () => { sendSelection(false); updateSlotCaret(); });
  window.addEventListener('resize', applyFit);
  new ResizeObserver(applyFit).observe(mf);
  document.fonts.ready.then(applyFit);
  function script(latex, role) { return role === 'superscript' ? `^{${latex}}` : role === 'subscript' ? `_{${latex}}` : latex; }
  // The atom enclosing the caret whose LaTeX starts with one of `prefixes`, with the
  // caret's selection restored. Registers a structure's own range, and finds the root a
  // raised symbol is being written into.
  function enclosingStructure(prefixes) {
    const saved = mf.selection?.ranges ?? [[mf.position, mf.position]];
    let found = null;
    for (let step = 0; step < 8; step++) {
      const info = mf.getElementInfo(mf.position);
      const latex = info?.latex;
      if (latex && prefixes.some(prefix => latex.startsWith(prefix))) { found = {index: mf.position, latex}; break; }
      if (mf.position <= 0 || mf.position > mf.lastOffset) break;
      // Children come before their parent in the flat atom list, so the parent's
      // index can be larger; only a stuck position ends the walk.
      const before = mf.position;
      if (!mf.executeCommand('moveBeforeParent') || mf.position < 0 || mf.position === before) break;
    }
    mf.selection = {ranges: saved};
    return found;
  }
  // True while the caret sits on a slot placeholder (a structure just opened, or the
  // user advanced into it). Writing then fills that slot instead of navigating lanes.
  function atPlaceholder() {
    const info = mf.getElementInfo(mf.position);
    return typeof info?.latex === 'string' && info.latex.startsWith('\\placeholder');
  }
  // Plain parentheses and brackets do not raise an atom's depth in MathLive, so scan
  // the source to the left of the caret for an opener still waiting for its closer.
  function insidePlainDelimiter() {
    let left = '';
    try { left = mf.getValue([0, mf.position], 'latex') || ''; } catch { return false; }
    const stack = [];
    for (let i = 0; i < left.length; i++) {
      const ch = left[i];
      if (ch === '\\') {
        const next = left[i + 1];
        if (next === '{') stack.push('{'); else if (next === '}') stack.pop();
        i++;
        continue;
      }
      if (ch === '(' || ch === '[' || ch === '{') stack.push(ch);
      else if (ch === ')' || ch === ']' || ch === '}') stack.pop();
      else if (ch === '|') { if (stack[stack.length - 1] === '|') stack.pop(); else stack.push('|'); }
    }
    return stack.length > 0;
  }
  // True while the caret sits inside a structure of its own: a focused slot, an open
  // script lane, a nested atom (fraction, root or delimited group), or plain
  // parentheses. A space there is invalid or meaningless, so the right-arrow action
  // navigates instead.
  function insideStructure() {
    if (scriptStack.length || atPlaceholder()) return true;
    if (atomDepth(mf.position) > 0) return true;
    return insidePlainDelimiter();
  }
  // The radicand inside `\sqrt{...}` (an existing index is skipped), or null when the
  // source is not a radical. Braces are matched so a nested fraction survives intact;
  // MathLive omits them for a single-token radicand (`\sqrt2`), which is kept as-is.
  function radicalRadicand(source) {
    if (!source || !source.startsWith('\\sqrt')) return null;
    let index = 5;
    if (source[index] === '[') {
      let depth = 0;
      for (; index < source.length; index++) {
        if (source[index] === '[') depth++;
        else if (source[index] === ']') { depth--; if (depth === 0) { index++; break; } }
      }
    }
    if (source[index] !== '{') return source.slice(index) || null;
    let depth = 0;
    const start = index + 1;
    for (; index < source.length; index++) {
      if (source[index] === '{') depth++;
      else if (source[index] === '}') { depth--; if (depth === 0) return source.slice(start, index); }
    }
    return null;
  }
  // The offset range covering a whole atom: children precede their parent in the flat
  // list, so the atom's own offset is the end and the first atom of greater depth below
  // it is the start. Selecting this range replaces the atom (nested content included).
  function atomRange(index) {
    const info = mf.getElementInfo(index);
    if (!info) return null;
    const depth = info.depth;
    let start = index;
    while (start > 0) {
      const prev = mf.getElementInfo(start - 1);
      if (!prev || prev.depth <= depth) break;
      start--;
    }
    return [start, index];
  }
  // Big operators carry their limits inside the same atom, but MathLive walks *into* them:
  // Backspace steps into a limit and eats its symbols one at a time, and once the limits are
  // empty it parks the caret in front of the atom, where the next press passes the operator
  // over and deletes the symbol before it instead. Treat them as one unit. Roots, fractions
  // and accents are left out: MathLive deletes those cleanly, content first.
  const unitStructures = ['\\int', '\\iint', '\\iiint', '\\oint', '\\sum', '\\prod', '\\coprod',
    '\\lim', '\\sup', '\\inf', '\\max', '\\min', '\\bigcup', '\\bigcap', '\\bigvee', '\\bigwedge',
    '\\bigoplus', '\\bigotimes', '\\bigodot', '\\biguplus', '\\bigsqcup'];
  const unitsByLength = [...unitStructures].sort((a, b) => b.length - a.length);
  // What is left of a unit atom once its own empty slots are stripped: `\int\limits_{}^{}`
  // and `\int\limits` both reduce to `\int`, while `\int_0^1` and `\lim_{x\to0}` keep their
  // content. Returns null for an atom that is not one of the unit structures.
  function structureState(latex) {
    if (typeof latex !== 'string') return null;
    const command = unitsByLength.find(name => latex === name || latex.startsWith(name));
    if (!command) return null;
    let rest = latex.slice(command.length).replace(/\\limits/g, '').replace(/\\placeholder/g, '').trim();
    // `_{{}}` (a placeholder's own braces inside the slot's) takes more than one pass.
    for (let prev = null; prev !== rest;) { prev = rest; rest = rest.replace(/(?:\^|_)?\{\}/g, '').trim(); }
    return {command, empty: rest.length === 0};
  }
  // The selection covering one whole atom, children included. A selection range starts *after*
  // its first offset, so the boundary in front of an atom's first child is one before the
  // start `atomRange` reports: `x+\int\limits_0^1` needs [2,7] to take its '+'. 
  function atomSelection(index) {
    const range = atomRange(index);
    return range ? [Math.max(0, range[0] - 1), range[1]] : null;
  }
  // The unit atom a collapsed delete takes as one step, if the caret is on one: inside it, or
  // pressed against it.
  function deleteUnit(backward) {
    const infoAt = index => (index < 0 || index > mf.lastOffset ? null : mf.getElementInfo(index));
    const stateAt = index => structureState(infoAt(index)?.latex);
    // Inside one of the operator's own slots (a script branch, not the top level). An empty
    // operator goes whole; a filled one is edited, because the caret sits in the slot the
    // user is working in.
    if (atomDepth(mf.position) > 0) {
      // Children come before their parent in the flat list, so the parent is the next atom
      // that sits shallower; walking the caret out instead loses a selected placeholder.
      let up = mf.position;
      while (up <= mf.lastOffset && atomDepth(up) >= atomDepth(mf.position)) up++;
      const parent = up <= mf.lastOffset ? infoAt(up) : null;
      const inside = parent && structureState(parent.latex) ? {index: up, latex: parent.latex} : enclosingStructure(unitStructures);
      const state = inside ? structureState(inside.latex) : null;
      return state?.empty ? {index: inside.index, ...state} : null;
    }
    // The atom the key is aimed at: to the left for Backspace, to the right for Delete.
    const aimed = backward ? mf.position : mf.position + 1;
    const aimedState = stateAt(aimed);
    if (aimedState) return {index: aimed, ...aimedState};
    // Emptying an operator's last slot parks the caret *in front* of the atom, so the key
    // aimed at the symbol before it finds the operator on the other side; only an empty one
    // is unambiguously that leftover.
    const other = backward ? mf.position + 1 : mf.position - 1;
    const otherState = stateAt(other);
    return otherState?.empty ? {index: other, ...otherState} : null;
  }
  // Backspace / Delete with MathLive's stall removed: whenever the command only moved the
  // caret (it stepped into a script or structure instead of deleting), run it once more so
  // the last symbol goes in a single keystroke. A filled big operator is selected whole on
  // the first press and taken by the next, so its limits go with it. Returns whether the source changed.
  function deleteStep(backward) {
    const before = mf.value, beforePosition = mf.position;
    const command = backward ? 'deleteBackward' : 'deleteForward';
    // A selection (one a unit delete put up, or a real one the user made) is deleted as it
    // stands.
    const [from, to] = selection();
    if (from !== to && !placeholderSelected()) { unitSelection = null; mf.executeCommand(command); return mf.value !== before; }
    const unit = deleteUnit(backward);
    if (unit) {
      const range = atomSelection(unit.index);
      if (!range) return false;
      mf.selection = {ranges: [range]};
      if (!unit.empty) { unitSelection = range; return false; }
      mf.insert('', {selectionMode:'after', focus:true});
      // Letters recorded inside the atom cannot be revised in place any more.
      invalidateOverlaps(range[0], range[1]);
      return mf.value !== before;
    }
    mf.executeCommand(command);
    if (mf.value === before && mf.position !== beforePosition) mf.executeCommand(command);
    return mf.value !== before;
  }
  // Opens or continues the script lane at the caret. Leaving a non-matching lane first
  // makes a subscript followed by a superscript reach the operator's other slot; an
  // operator's existing branch is reused, so a filled slot is replaced, not nested in.
  function openLane(role) {
    while (scriptStack.length && scriptStack.at(-1) !== role) { mf.executeCommand('moveAfterParent'); scriptStack.pop(); }
    if (scriptStack.at(-1) !== role) {
      mf.executeCommand(role === 'superscript' ? 'moveToSuperscript' : 'moveToSubscript');
      scriptStack.push(role);
    }
  }
  function replaceRange(range, value, role, id) {
    const [start,end] = range;
    mf.selection = {ranges:[range]};
    mf.insert(value == null ? '' : script(value, role), {format:'latex', selectionMode:value == null ? 'after' : 'item', focus:true});
    const picked = value == null ? [start,start] : selection();
    const length = end - start;
    shiftAfter(end, (picked[1] - picked[0]) - length);
    if (value == null) { history.delete(id); rootIndexes.delete(id); } else history.set(id, picked);
    if (value != null) mf.position = picked[1];
    return picked;
  }
  function insertFractionEdit(e) {
    const operandRanges = (e.operandIDs || []).map(id => history.get(id)).filter(Boolean);
    const punctuation = (e.removedParenthesisIDs || []).map(id => history.has(id) ? [id, history.get(id)] : null).filter(Boolean);
    const triggers = (e.replaces || []).map(id => history.has(id) ? [id, history.get(id)] : null).filter(Boolean);
    if (!operandRanges.length) {
      if ((e.operandIDs || []).length) return;
      const selected=selection();
      const numerator=selected[0]===selected[1] ? '' : mf.getValue(selected,'latex');
      mf.insert(fractionSource(numerator), {format:'latex', selectionMode:'placeholder', focus:true});
      scriptStack=[]; return;
    }
    const all = [...operandRanges, ...punctuation.map(([,r])=>r), ...triggers.map(([,r])=>r)];
    const range = [Math.min(...all.map(r=>r[0])), Math.max(...all.map(r=>r[1]))];
    let numerator = mf.getValue([Math.min(...operandRanges.map(r=>r[0])),Math.max(...operandRanges.map(r=>r[1]))], 'latex');
    for (const [,r] of punctuation) {
      const token = mf.getValue(r, 'latex');
      const at = numerator.indexOf(token);
      if (at >= 0) numerator = numerator.slice(0,at) + numerator.slice(at+token.length);
    }
    for (const id of [...(e.operandIDs || []),...(e.removedParenthesisIDs || []),...(e.replaces || [])]) history.delete(id);
    const beforeOffset = mf.lastOffset;
    mf.selection = {ranges:[range]};
    mf.insert(fractionSource(numerator), {format:'latex', selectionMode:'placeholder', focus:true});
    const delta = mf.lastOffset - beforeOffset;
    shiftAfter(range[1], delta);
    scriptStack=[];
  }
  function atomBefore(index) {
    if (index <= 0) return null;
    try { return mf.getValue([index - 1, index], 'latex'); } catch { return null; }
  }
  function atomDepth(index) {
    if (index < 0 || index > mf.lastOffset) return 0;
    try { return mf.getElementInfo(index)?.depth ?? 0; } catch { return 0; }
  }
  // A subscript branch already written into the run being replaced. Its children come
  // first in the flat list, then the script atom itself, so the branch ends at the first
  // atom at the base depth whose LaTeX is `_{...}`. A selection range ending at `b`
  // covers the atom at index `b`, so the returned `end` is where the branch's own atom
  // sits. Returns the inner source, that end, and the ids recorded inside the branch.
  function followingSubscript(index, baseDepth) {
    let i = index;
    while (i <= mf.lastOffset && atomDepth(i) > baseDepth) i++;
    const latex = i <= mf.lastOffset ? (() => { try { return mf.getElementInfo(i)?.latex; } catch { return null; } })() : null;
    if (typeof latex !== 'string' || !latex.startsWith('_')) return null;
    const body = latex.slice(1);
    const content = body.startsWith('{') && body.endsWith('}') ? body.slice(1, -1) : body;
    const ids = [];
    for (const [id, range] of history) if (range[0] >= index && range[1] <= i) ids.push(id);
    return {content, end: i, ids};
  }
  // Moves a recovered condition into the structure's own slots: `x` becomes its lower
  // limit, and a whole `x\to0` fills both. The absorbed symbol keeps its id so a later
  // correction still finds it.
  function seedStructureSlot(recovered) {
    const match = /^(.*?)(?:\\(?:to|rightarrow)|→)(.*)$/.exec(recovered.content);
    const variable = match ? match[1] : recovered.content;
    const value = match ? match[2] : null;
    if (variable) {
      const before = mf.lastOffset;
      mf.insert(variable, {format:'latex', selectionMode:'item', focus:true});
      const added = mf.lastOffset - before;
      const picked = selection();
      shiftAfter(picked[0], added);
      for (const id of recovered.ids) history.set(id, picked);
      mf.position = picked[1];
    }
    if (value != null) {
      if (variable) mf.position = Math.min(mf.lastOffset, mf.position + 1);
      mf.executeCommand('moveToNextPlaceholder');
      if (value) {
        const before = mf.lastOffset;
        const at = mf.position;
        mf.insert(value, {format:'latex', selectionMode:'item', focus:true});
        const added = mf.lastOffset - before;
        shiftAfter(at, added);
        mf.position = Math.min(mf.lastOffset, at + added);
      }
    }
  }
  function insertStructureEdit(e) {
    const source = structureSource[e.structure];
    if (!source) return;
    const replacements = (e.replaces || []).map(id => history.has(id) ? [id, history.get(id)] : null).filter(Boolean);
    if ((e.replaces || []).length && !replacements.length) return;
    const beforeOffset = mf.lastOffset;
    if (replacements.length) {
      const start = Math.min(...replacements.map(([, range]) => range[0]));
      let end = Math.max(...replacements.map(([, range]) => range[1]));
      // Ink written below the run (a limit's condition) can reach the editor before the
      // replacement lands. Fold that branch into the structure instead of leaving a
      // dangling `\lim_{...}_{x}` after it.
      const absorbable = e.structure === 'lim' || e.structure === 'sum' || e.structure === 'int';
      const recovered = absorbable ? followingSubscript(end + 1, atomDepth(end)) : null;
      if (recovered) end = recovered.end;
      mf.selection = {ranges: [[start, end]]};
      for (const id of [...replacements.map(([id]) => id), ...(recovered?.ids ?? [])]) { history.delete(id); rootIndexes.delete(id); }
      mf.insert(source, {format:'latex', selectionMode:'placeholder', focus:true});
      shiftAfter(end, mf.lastOffset - beforeOffset);
      if (recovered) seedStructureSlot(recovered);
    } else {
      mf.insert(source, {format:'latex', selectionMode:'placeholder', focus:true});
    }
    // Keep the newly focused root radicand visibly active as soon as it is inserted.
    if (e.structure === 'sqrt') updateSlotCaret();
    // A later revision replaces the whole structure atom, its slots included, so a
    // corrected operator takes its limits with it.
    const anchor = enclosingStructure(structureCommands[e.structure]);
    history.set(e.id, anchor ? [anchor.index, anchor.index] : selection());
    // The caret sits in the structure's first slot: a script lane for the operators.
    scriptStack = e.structure === 'sqrt' ? [] : ['subscript'];
  }
  // A raised symbol written while the caret is in a root becomes that root's index.
  // Anywhere else it stays an ordinary superscript. `anchorIndex` is set when the
  // symbol being rewritten is itself an index: it points straight at its root atom.
  function insertRootIndexEdit(e, anchorIndex) {
    let radical = null;
    if (anchorIndex != null) {
      const known = mf.getElementInfo(anchorIndex)?.latex;
      if (typeof known === 'string' && known.startsWith('\\sqrt')) radical = {index: anchorIndex, latex: known};
    }
    if (!radical) radical = enclosingStructure(structureCommands.root);
    const radicand = radical ? radicalRadicand(radical.latex) : null;
    // Swift only sends a root index while the radicand is still pending, so a filled
    // radicand keeps its content and a revision rewrites just the index.
    if (!radical || radicand === null || e.latex == null) {
      rootIndexes.delete(e.id);
      openLane('superscript');
      mf.insert(e.latex ?? '', {format:'latex', selectionMode:'item', focus:true});
      const [start,end]=selection(); history.set(e.id,[start,end]); mf.position=end;
      return;
    }
    const empty = radicand === '' || radicand === placeholder;
    const source = `\\sqrt[${e.latex}]{${empty ? placeholder : radicand}}`;
    const range = atomRange(radical.index);
    if (!range) return;
    const beforeOffset = mf.lastOffset;
    mf.selection = {ranges: [range]};
    mf.insert(source, {format:'latex', selectionMode: empty ? 'placeholder' : 'after', focus:true});
    shiftAfter(range[1], mf.lastOffset - beforeOffset);
    scriptStack = [];
    const anchor = enclosingStructure(structureCommands.root);
    const root = anchor ? anchor.index : radical.index;
    rootIndexes.set(e.id, root);
    history.set(e.id, [root, root]);
  }
  window.mathLive = {
    ready: () => loaded,
    readyPromise,
    setLatex(latex, fontSize) {
      applying = true; autoClosed = 0;
      mf.setValue(latex || '', {selectionMode:'after', silenceNotifications:true});
      mf.style.fontSize = `${fontSize || 24}px`;
      history.clear(); rootIndexes.clear(); scriptStack=[]; mf.resetUndo(); mf.focus(); mf.executeCommand('scrollIntoView'); applyFit(); applying = false; updateSlotCaret();
      // The host keeps its static preview up until the field holds this source: swapping it
      // out first showed the previous equation (in the previous size) for a frame.
      send('layout', {latex: mf.value, ...contentInset});
    },
    applyHandwriting(edits, autoClose = false) {
      applying = true;
      for (const edit of edits) {
        // Handwriting is always math. A field left in LaTeX or text mode (a stray `\` key, a
        // click into the wrong atom) would insert `\div` as typed letters and show the source.
        if (mf.mode !== 'math') mf.mode = 'math';
        // The word `abs` opens the same delimiter pair as a written bar, even
        // when automatic closing of ordinary handwritten brackets is disabled.
        const absolute = edit.structure === 'abs';
        const e = absolute ? {...edit, structure: null, latex: '|'} : edit;
        const closePair = autoClose || absolute;
        if (e.structure === 'root') { insertRootIndexEdit(e); continue; }
        if (e.structure) { insertStructureEdit(e); continue; }
        if (e.fraction) { insertFractionEdit(e); continue; }
        const replacements = (e.replaces || []).map(id => history.has(id) ? [id, history.get(id)] : null).filter(Boolean);
        if (e.replaces?.length && !replacements.length) continue;
        // Rewriting a symbol that lives in a root's index keeps the root and swaps the index.
        const indexAnchor = replacements.map(([id]) => rootIndexes.get(id)).find(offset => offset != null);
        if (indexAnchor != null) {
          for (const [id] of replacements) { history.delete(id); rootIndexes.delete(id); }
          insertRootIndexEdit(e, indexAnchor);
          continue;
        }
        let range;
        if (replacements.length) {
          const start = Math.min(...replacements.map(([,r]) => r[0]));
          const end = Math.max(...replacements.map(([,r]) => r[1]));
          range = [start,end]; replacements.forEach(([id])=>history.delete(id));
        } else if (history.has(e.id)) range = history.get(e.id);
        else range = null;
        if (range) {
          const close = e.latex == null && history.get(e.id + ':close');
          if (close) {
            history.delete(e.id + ':close');
            mf.selection = {ranges:[close]};
            mf.insert('', {selectionMode:'after', focus:true});
            autoClosed = Math.max(0, autoClosed - 1);
          }
          const oldCaret=mf.position, oldLast=mf.lastOffset;
          const picked=replaceRange(range, e.latex, 'body', e.id);
          const delta=mf.lastOffset-oldLast;
          mf.position=Math.max(0,Math.min(mf.lastOffset,oldCaret>=range[1]?oldCaret+delta:(oldCaret>range[0]?range[0]+picked[1]-picked[0]:oldCaret)));
          // A correction that lands an opener brings its closer too, so picking `|`
          // fills the absolute-value pair just like ink. An opener replaced just
          // before its closer absorbs that closer instead of doubling it.
          if (closePair && e.latex && closers[e.latex] && !close && !history.has(e.id + ':close')) {
            const mate = closers[e.latex];
            if (mf.getValue([picked[1], picked[1] + 1], 'latex') === mate) {
              const from = picked[1], to = picked[1] + 1;
              for (const [id, r] of history) if (r[0] >= from && r[1] <= to) history.delete(id);
              for (const [id, r] of history) if (r[0] >= to) history.set(id, [r[0] - 1, r[1] - 1]);
              for (const [id, offset] of rootIndexes) if (offset >= to) rootIndexes.set(id, offset - 1);
              mf.selection = {ranges: [[from, to]]};
              mf.insert('', {selectionMode:'after', focus:true});
              mf.position = from;
              autoClosed = Math.max(0, autoClosed - 1);
            } else if (mf.position === mf.lastOffset && picked[1] === mf.lastOffset) {
              const end = picked[1];
              const before = mf.lastOffset;
              mf.insert(mate, {format:'latex', selectionMode:'after', focus:true});
              const added = mf.lastOffset - before;
              shiftAfter(end, added);
              history.set(e.id + ':close', [end, end + added]);
              mf.position = end; autoClosed++;
            }
          }
        } else {
          if (e.role === 'body') { exitScripts(); }
          // The native side sends 'inherit' for symbols that keep the lane they are in.
          // A superscript/subscript either continues the open lane (x^{ab}, i=1), fills a
          // focused slot placeholder, or reaches the matching slot of the atom at the
          // caret; arrow keys leave (navigate).
          else if ((e.role === 'superscript' || e.role === 'subscript') && !atPlaceholder()) { openLane(e.role); }
          const next = mf.getValue([mf.position, mf.position + 1], 'latex');
          // A hand-written arrow after a limit's variable types over the arrow the
          // template already carries, and steps into the approached-value slot.
          if (e.latex === '\\to' && next === '\\to' && enclosingStructure(structureCommands.lim)) {
            const at = mf.position;
            history.set(e.id, [at, at + 1]);
            mf.position = at + 1;
            mf.executeCommand('moveToNextPlaceholder');
            continue;
          }
          // Anything else written after a filled limit variable (the approached value)
          // belongs in the slot past the template's arrow, not before it.
          const beforeCaret = atPlaceholder() ? null : atomBefore(mf.position);
          if (e.latex && e.role !== 'body' && next === '\\to' && beforeCaret
              && !String(beforeCaret).startsWith('\\placeholder')
              && enclosingStructure(structureCommands.lim)) {
            mf.position = Math.min(mf.lastOffset, mf.position + 1);
            mf.executeCommand('moveToNextPlaceholder');
          }
          if (autoClosed && next === e.latex && Object.values(closers).includes(e.latex)) {
            // A hand-written closer types over the auto one instead of doubling it.
            const at = mf.position; autoClosed--; history.set(e.id,[at,at+1]); mf.position = at + 1; continue;
          }
          mf.insert(e.latex, {format:'latex',selectionMode:'item',focus:true});
          const [start,end]=selection(); history.set(e.id,[start,end]); mf.position=end;
          if (closePair && closers[e.latex]) {
            const before = mf.lastOffset;
            mf.insert(closers[e.latex], {format:'latex',selectionMode:'after',focus:true});
            const added = mf.lastOffset - before;
            shiftAfter(end, added);
            history.set(e.id + ':close', [end, end + added]); // linked closer; deleted with its opener
            mf.position = end; autoClosed++;
          }
        }
      }
      applying = false;
      mf.resetUndo(); mf.executeCommand('scrollIntoView'); applyFit(); changed(edits.some(e => e.coalescesUndo) ? 'handwritingRevision' : 'handwriting'); sendSelection(false); updateSlotCaret();
    },
    reviseHandwriting(id, latex, role) {
      if (!history.has(id)) return;
      this.applyHandwriting([{id, latex, role, replaces:[id]}]);
    },
    insertFraction() {
      applying = true;
      mf.insert(fractionSource(''), {format:'latex', selectionMode:'placeholder', focus:true});
      applying = false; scriptStack=[]; mf.resetUndo(); mf.executeCommand('scrollIntoView'); applyFit(); changed('handwriting'); sendSelection(false); updateSlotCaret();
    },
    navigate(command) {
      const keep = scriptStack, wasAuto = autoClosed;
      userSelection();
      // Keyboard focus may sit on the canvas (trackpad input); MathLive hides its caret when blurred.
      mf.focus();
      // Vertical navigation needs atom geometry from the latest source. WebKit
      // can throttle the render frame, leaving old atoms (and selection boxes).
      // Backspace in an empty field steps back to the previous line.
      if (command === 'deleteBackward' && mf.value === '') { send('finish', {insertNewline:false, thenDelete:true}); return; }
      if (command === 'deleteBackward' && wasAuto) {
        const p = mf.position;
        if (closers[mf.getValue([p-1,p],'latex')] === mf.getValue([p,p+1],'latex')) {
          mf.selection = {ranges:[[p-1,p+1]]}; mf.insert('', {selectionMode:'after', focus:true}); autoClosed = wasAuto - 1; return;
        }
      }
      mf.executeCommand('scrollIntoView');
      const levels = keep.slice();
      if (command === 'moveToNextChar' && levels.length) { scriptStack = levels; exitScripts(); return; }
      if (command === 'moveDown' && levels.at(-1) === 'superscript') { mf.executeCommand('moveAfterParent'); scriptStack = levels.slice(0,-1); return; }
      if (command === 'moveUp' && levels.at(-1) === 'subscript') { mf.executeCommand('moveAfterParent'); scriptStack = levels.slice(0,-1); return; }
      if (command === 'deleteBackward' || command === 'deleteForward') {
        // A Delete pressed against the equation in the note enters it and drops one
        // symbol, the way the same key drops one character from a text run.
        if (deleteStep(command === 'deleteBackward')) { changed('keyboard'); mf.resetUndo(); applyFit(); }
      } else {
        mf.executeCommand(command);
      }
      updateSlotCaret();
    },
    // The right arrow / Tab / the panel's right zone at the top level: insert a real
    // space so terms separate, the way a typed space would. Inside a structure the
    // caret navigates instead; `fallback` is the navigation the control already did
    // ('advance' for Tab and the panel zone, 'moveToNextChar' for the arrow key).
    insertSpace(fallback) {
      mf.focus();
      mf.executeCommand('scrollIntoView');
      if (insideStructure()) {
        if (fallback === 'advance') this.advance(); else this.navigate('moveToNextChar');
        return false;
      }
      // Nothing to separate in an empty field, and with content to the right the control
      // moves the caret; a space is only made at the end of the line.
      if (mf.lastOffset === 0 || mf.position < mf.lastOffset) {
        if (fallback === 'advance') this.advance(); else this.navigate('moveToNextChar');
        return false;
      }
      return this.typeSpace();
    },
    // A real space at the caret, wherever it is.
    typeSpace(source = 'handwriting') {
      mf.focus();
      const at = mf.position;
      applying = true;
      mf.insert('\\ ', {format:'latex', selectionMode:'after', focus:true});
      applying = false;
      const added = mf.lastOffset - at;
      if (added > 0) shiftAfter(at, added);
      scriptStack = []; autoClosed = 0;
      mf.resetUndo(); applyFit();
      changed(source); sendSelection(false); updateSlotCaret();
      return true;
    },
    advance() {
      userSelection();
      mf.focus();
      mf.executeCommand('scrollIntoView');
      // Move from an empty numerator to its denominator, or past a filled
      // fraction/script. Placeholder navigation alone is a no-op once filled.
      const before=JSON.stringify(mf.selection);
      mf.executeCommand('moveToNextPlaceholder');
      if (JSON.stringify(mf.selection) !== before) { sendSelection(false); updateSlotCaret(); return; }
      // MathLive reports success for these commands even when they cannot move
      // (an auto-closed bracket has no placeholder or parent), so fall back to a
      // plain step whenever the caret did not actually move. Otherwise the trackpad
      // advance button cannot exit brackets that the arrow keys step out of.
      mf.executeCommand('moveAfterParent');
      if (JSON.stringify(mf.selection) === before) mf.executeCommand('moveToNextChar');
      sendSelection(false); updateSlotCaret();
    },
    // Match MathLive's selection chrome to the host's regular highlight color.
    setSelectionColors(background, foreground) {
      if (background) mf.style.setProperty('--selection-background-color', background);
      if (foreground) mf.style.setProperty('--selection-color', foreground);
    },
    setMaxWidth(width) { maxWidth=width; applyFit(); },
    setSelection(ranges) { applying=true; mf.selection={ranges}; applying=false; sendSelection(false); updateSlotCaret(); },
    focusAt(x, y) {
      mf.focus();
      mf.executeCommand('scrollIntoView');
      const offset=offsetNearPoint(x,y);
      if (offset >= 0) { userSelection(); mf.position=offset; updateSlotCaret(); }
    },
    // Places the caret at one end of the field, for a Delete or arrow key pressed against
    // the equation in the note: the equation is entered at the boundary the key came from.
    focusBoundary(edge) {
      mf.focus();
      mf.executeCommand('scrollIntoView');
      userSelection();
      mf.position = edge === 'start' ? 0 : mf.lastOffset;
      updateSlotCaret();
    },
    selection: () => mf.selection?.ranges ?? [],
    latex: () => mf.value,
    render(latex, size) {
      applying=true; fitting=false; mf.style.transform='none'; mf.setValue(latex || '', {selectionMode:'after'}); mf.style.fontSize=`${size || 24}px`; applying=false;
      return mf.getValue('latex');
    }
  };
  const multilineSource = /\\(?:displaylines|begin\{(?:align\*?|gather\*?|multline|split|aligned|gathered|array|matrix|pmatrix|bmatrix|Bmatrix|vmatrix|Vmatrix|cases)\})/;
  function insertMathLineBreak() {
    const source = mf.getValue('latex') || '';
    if (!multilineSource.test(source)) {
      // MathLive only creates rows inside a multiline environment. Promote the
      // current expression once, then let its normal Return command add each row.
      applying = true;
      mf.setValue(`\\displaylines{${source}}`, {selectionMode:'after'});
      applying = false;
      history.clear(); rootIndexes.clear(); scriptStack = []; autoClosed = 0;
      sendSelection(true);
    }
    mf.executeCommand('commit');
    applyFit();
    updateSlotCaret();
  }
  window.addEventListener('error', e => send('failure', {message:e.error?.stack || e.message || 'script error'}));
  window.addEventListener('unhandledrejection', e => send('failure', {message:String(e.reason || 'promise rejection')}));
  window.addEventListener('keydown', e => {
    if (['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Tab'].includes(e.key)) mf.executeCommand('scrollIntoView');
    if (e.key === ' ' && !e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey && mf.value !== '') {
      e.preventDefault(); e.stopImmediatePropagation(); window.mathLive.typeSpace('keyboard'); return;
    }
    if (e.key === 'Tab' && !e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey) {
      e.preventDefault(); e.stopImmediatePropagation(); window.mathLive.advance(); return;
    }
    // Backspace in an empty field steps back to the end of the previous line.
    if (e.key === 'Backspace' && mf.value === '' && !e.metaKey && !e.ctrlKey && !e.altKey) {
      e.preventDefault(); e.stopImmediatePropagation(); send('finish', {insertNewline:false, thenDelete:true}); return;
    }
    // A collapsed Backspace/Delete goes through `deleteStep`, so a keystroke that would
    // only step into a script or stall on an emptied structure still removes the last
    // symbol in one press. A real selection keeps MathLive's own handling.
    if ((e.key === 'Backspace' || e.key === 'Delete') && !e.metaKey && !e.ctrlKey && !e.altKey) {
      const [from, to] = selection();
      const unit = unitSelection && unitSelection[0] === from && unitSelection[1] === to;
      if (from === to || unit || placeholderSelected()) {
        e.preventDefault(); e.stopImmediatePropagation();
        mf.focus();
        if (deleteStep(e.key === 'Backspace')) { changed('keyboard'); mf.resetUndo(); applyFit(); }
        updateSlotCaret();
        return;
      }
    }
    if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); send('finish', {insertNewline:false}); return; }
    if (e.key === 'Enter' && !e.metaKey && !e.ctrlKey && !e.altKey) {
      e.preventDefault(); e.stopImmediatePropagation(); insertMathLineBreak(); return;
    }
    if (!(e.metaKey || e.ctrlKey) || e.altKey) return;
    if (e.key.toLowerCase() === 'z') { e.preventDefault(); e.stopImmediatePropagation(); send(e.shiftKey ? 'redo' : 'undo', {}); }
    if (e.key.toLowerCase() === 'y') { e.preventDefault(); e.stopImmediatePropagation(); send('redo', {}); }
  }, true);
})();
