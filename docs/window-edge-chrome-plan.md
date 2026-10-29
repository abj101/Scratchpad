# Window edge chrome: plan and agent prompts

Hovering the top of the window shows the traffic lights, gives an arrow cursor (never the
canvas cursor), lets you drag the window, and shows a dark gray Liquid Glass border around
the window so the edges are easy to grab.

## Decisions (confirmed)

- **Top zone:** full width, from the window's top edge down to the bottom of the tool bar:
  `FloatingChromeLayout.topPadding + toolBarHeight` = 60pt.
- **Traffic lights:** shown whenever the pointer is in the top zone. Today they only show in
  a 130×44pt top-left box.
- **Cursor:** an arrow everywhere in the top zone. Today the canvas cursor shows in the 8pt
  strip above the tool bar, because the canvas runs to the window top
  (`.ignoresSafeArea(edges: .top)`).
- **Drag:** mouse-down in the top zone (outside tool bar controls) drags the window.
- **Border:** visual only, sitting on the native resize edges; it does no hit testing.
  - 6pt ring that follows the window corner radius.
  - Dark gray tint at about 0.7 opacity.
  - Liquid Glass (`.glassEffect`) on macOS 26+; `.ultraThinMaterial` plus a dark gray fill on
    macOS 14/15 (the package targets macOS 14).
- **Border lifetime:**
  - Appears when the pointer enters the top zone.
  - Stays while the pointer is within 12pt of any window edge, or while a live resize or
    window drag is in progress.
  - Otherwise fades out over 0.18s, or instantly when Reduce Motion is on.
  - Hidden when the window is not key, in full screen, or while the canvas cursor is locked
    (Tablet modes).
- **Out of scope:**
  - Custom resize handles.
  - Double-click on the top zone to zoom.
  - New automated UI tests. Testing is manual (see Task 5).

## Task graph

```
T1 Foundation ──┬── T2 Top drag strip   (ContentView.swift: `detail`)
                ├── T3 Hot zone + state (AutoHideTrafficLights.swift)
                └── T4 Border view      (new WindowEdgeBorder.swift + one overlay in ContentView `body`)
                         └── T5 Integrate, build, manual test checklist
```

T2, T3 and T4 can run in parallel after T1. Each owns separate files or hunks. T2 and T4
both touch `ContentView.swift`, but in different places: `detail` and `body`.

Build check after every task:

```bash
xcodegen generate -q && xcodebuild -scheme Scratchpad -derivedDataPath build build -quiet
```

Run the app with `scripts/run.sh`.

---

## Orchestrator prompt (paste into ChatGPT / Codex)

```
You are orchestrating a small macOS SwiftUI/AppKit feature in the Scratchpad repo
(branch off the current branch). Read docs/window-edge-chrome-plan.md fully first; it holds
the confirmed design decisions, the task graph, and one self-contained prompt per task.

Execute the tasks in order T1 → (T2, T3, T4, in parallel if you can run sub-agents,
otherwise sequentially) → T5. For each task:
1. Do exactly what its prompt says, nothing more. Match the surrounding code style
   (doc comments on types, short comments explaining "why", no new dependencies).
2. Build with:
   xcodegen generate -q && xcodebuild -scheme Scratchpad -derivedDataPath build build -quiet
   Fix any compile errors before moving on.
3. Commit with message "feat(chrome): <task title>".
Do not change design decisions. If something in the plan is impossible as written, stop
and report what and why instead of improvising. At the end, print the T5 manual test
checklist for the user. Do not attempt to automate the manual tests.
```

---

## T1: Foundation (shared constant and state object)

```
Repo: Scratchpad (macOS app, SwiftUI + AppKit, deployment target macOS 14).
Task T1 of the "window edge chrome" feature (see docs/window-edge-chrome-plan.md).

Goal: add the shared pieces that T2 to T4 build on. No behavior change yet.

1. In Sources/CanvasKit/WritingLayout.swift, inside `public enum FloatingChromeLayout`, add:
       /// The window's top band: everything above the tool bar's bottom edge. Hovering it
       /// shows the traffic lights and the window border; it drags the window.
       public static let topZoneHeight: CGFloat = topPadding + toolBarHeight

2. In Sources/Scratchpad/AutoHideTrafficLights.swift, add at file scope:
       /// Window-edge hover state shared by the traffic-light hider and the border overlay.
       final class WindowChromeState: ObservableObject {
           @Published var showsBorder = false
       }
   Give `AutoHideTrafficLights` a stored property `let state: WindowChromeState`. Pass it
   into `HostView` and from there into `Hider` (`weak var state` or a strong reference;
   nothing reads or writes it yet).

3. In Sources/Scratchpad/ContentView.swift, `ContentView` gets
   `@StateObject private var chromeState = WindowChromeState()` and changes
   `.background(AutoHideTrafficLights())` to `.background(AutoHideTrafficLights(state: chromeState))`.

Build and make sure it compiles. Don't touch anything else.
```

## T2: Top drag strip (arrow cursor, no canvas input, drags the window)

```
Repo: Scratchpad (macOS, SwiftUI + AppKit, target macOS 14). Task T2 of
docs/window-edge-chrome-plan.md. T1 is done: `FloatingChromeLayout.topZoneHeight` (60pt)
exists.

Problem: the canvas (CanvasRepresentable in Sources/Scratchpad/ContentView.swift, `detail`)
ignores the top safe area, so it runs to the window's top edge. The floating tool bar sits
8pt below. In that sliver, and beside the tool bar, the canvas still shows its custom cursor
and accepts input.

Do this, in Sources/Scratchpad/ContentView.swift only:

1. Add a private NSViewRepresentable `TopDragStrip` whose NSView:
   - overrides `resetCursorRects()` with `addCursorRect(bounds, cursor: .arrow)`
     (same as the existing `ArrowCursorRegion` in this file);
   - overrides `mouseDown(with:)` to call `window?.performDrag(with: event)`;
   - returns true from `acceptsFirstMouse(for:)`, so the first click on an inactive window
     drags it;
   - does NOT override hitTest. It must catch hits, so the canvas's `pointerIsOverCanvas`
     (a hitTest on the content view) turns false there.
   Document it in one line, like the neighbouring types.

2. In `detail`, add an overlay on the canvas BEFORE (that is, underneath) the existing
   `.overlay(alignment: .top) { FloatingChrome(...) }`, so tool bar controls still win
   clicks:
       .overlay(alignment: .top) {
           TopDragStrip()
               .frame(height: FloatingChromeLayout.topZoneHeight)
               .frame(maxWidth: .infinity)
               .ignoresSafeArea(edges: .top)
               .onHover { canvasHandle.scrollView?.canvasView.setToolbarHovered($0) }
       }
   `setToolbarHovered` already exists on CanvasView and fades the canvas cursor into the
   arrow. Reusing it keeps that animation. Check the strip's top really reaches the window's
   top edge (the window uses `.windowStyle(.hiddenTitleBar)`).

3. Check that the existing `ToolMenuClickCatcher` overlay still closes the color/width menu
   when clicking in the strip. If the strip now swallows that click, close the menu in
   `mouseDown` too, by setting `settings.toolMenu = nil` or whatever ToolMenuClickCatcher
   does (read it, don't guess).

Don't touch AutoHideTrafficLights.swift or the border. Build.
```

## T3: Full-width hot zone and border visibility state

```
Repo: Scratchpad (macOS, target macOS 14). Task T3 of docs/window-edge-chrome-plan.md.
T1 is done: `WindowChromeState` (`@Published var showsBorder`) exists and is passed into
`AutoHideTrafficLights` → `HostView` → `Hider` in
Sources/Scratchpad/AutoHideTrafficLights.swift. `FloatingChromeLayout.topZoneHeight` (60pt,
in CanvasKit) exists.

Edit only Sources/Scratchpad/AutoHideTrafficLights.swift:

1. Traffic lights: change `pointerIsInHotZone()` to the full-width top zone:
   `p.x >= 0 && p.x <= window.frame.width && p.y > window.frame.height - FloatingChromeLayout.topZoneHeight`.
   Delete the now-unused `hotWidth`. Update the type's doc comment. `import CanvasKit` if
   needed.

2. Border state: in `update()` (and `install()`), compute and set `state.showsBorder`:
   - turn on when the pointer is in the top zone;
   - stay on while it is on AND (the pointer is within 12pt of any window edge
     OR `window.inLiveResize`);
   - otherwise turn off;
   - always off when `!window.isKeyWindow` or `window.styleMask.contains(.fullScreen)`
     or the cursor is hidden by the canvas lock. Use `CGCursorIsVisible() == 0` as the
     lock check (CursorLock in CanvasKit hides the cursor while locked); don't add API to
     CanvasKit.
   Only assign when the value changes, so SwiftUI doesn't re-render on every mouse move.
   Put the 12pt in a `private static let edgeSlop: CGFloat = 12`.

3. Window drag: while the user drags the window from the top zone the pointer stays inside
   it, so the border stays on by rule 2. Confirm `.leftMouseDragged` is already in the local
   monitor (it is). During a live resize, add `NSWindow.willStartLiveResizeNotification` and
   `didEndLiveResizeNotification` to the observed notifications, so the state re-evaluates
   at both ends.

4. `mouseExited` currently hides the traffic lights. Make it also re-run the border rule
   instead of forcing it off. The pointer may have left the titlebar container but still be
   near an edge.

Build. Don't touch ContentView.swift.
```

## T4: Border view

```
Repo: Scratchpad (macOS SwiftUI app; package deployment target macOS 14; built with the
macOS 26 SDK). Task T4 of docs/window-edge-chrome-plan.md. T1 is done:
`WindowChromeState` (ObservableObject, `@Published var showsBorder`) exists in
Sources/Scratchpad/AutoHideTrafficLights.swift, and `ContentView` owns it as
`@StateObject private var chromeState`.

1. Create Sources/Scratchpad/WindowEdgeBorder.swift with
   `struct WindowEdgeBorder: View { @ObservedObject var state: WindowChromeState }`:
   - A ring 6pt wide around the whole view, following the window corner radius. Put the
     radius in a `private static let cornerRadius`. Start with 16 for macOS 26 windows and
     10 for macOS 14/15, chosen with `#available`. Leave a comment that these are tuning
     knobs.
   - Build the ring by masking a fill with `RoundedRectangle(cornerRadius:).strokeBorder(lineWidth: 6)`.
   - Fill on macOS 26+ (`if #available(macOS 26, *)`):
       `.glassEffect(.regular.tint(Color(white: 0.22).opacity(0.7)), in: RoundedRectangle(...))`
     masked to the ring.
   - Fill on older systems: `.ultraThinMaterial` with `Color(white: 0.22).opacity(0.7)` over
     it, masked to the ring.
   - `.opacity(state.showsBorder ? 1 : 0)`, animated with `.easeInOut(duration: 0.18)`, or
     no animation when `accessibilityReduceMotion` is on (`@Environment(\.accessibilityReduceMotion)`).
   - `.allowsHitTesting(false)` and `.ignoresSafeArea()`. The native resize edges and the
     top drag strip must keep working underneath.
   Check the glassEffect API and its spelling against the SDK. If tint on a masked glass
   shape doesn't render, use the closest working variant and say what you used.

2. In Sources/Scratchpad/ContentView.swift, in `ContentView.body` only (not `detail`), add
   `.overlay { WindowEdgeBorder(state: chromeState) }` after the `.frame(...)` modifiers.

Build. To eyeball it without T3, temporarily default `showsBorder = true`, then revert.
```

## T5: Integrate, build, hand off for manual testing

```
Repo: Scratchpad. Task T5 of docs/window-edge-chrome-plan.md. T1 to T4 are merged.

1. Resolve any merge conflicts in Sources/Scratchpad/ContentView.swift: T2 touched
   `detail`, T4 touched `body`.
2. Build:
   xcodegen generate -q && xcodebuild -scheme Scratchpad -derivedDataPath build build -quiet
   and run the unit tests: swift test. Report any failures with their output; don't paper
   over them.
3. Review the diff for leftovers: unused `hotWidth`, a temporary `showsBorder = true`,
   debug prints.
4. Launch with scripts/run.sh and give the user this checklist. Do not automate it:
   - [ ] Hover above the tool bar, and to its left and right: arrow cursor, never the
         canvas dot.
   - [ ] Same hover: the traffic lights appear (not just in the top-left corner).
   - [ ] Same hover: the dark glass border fades in around the whole window.
   - [ ] Drag anywhere in that band (not on a button): the window moves. The tool bar
         buttons still work.
   - [ ] Move from the top band down the left or right edge: the border stays.
   - [ ] Resize from a side or bottom edge: the border stays, and resizing works.
   - [ ] Move into the middle of the canvas: the border fades, and the traffic lights hide.
   - [ ] Tablet / absolute mode while drawing: the border never appears.
   - [ ] Full screen: no border.
   - [ ] Reduce Motion on: the border appears and disappears without fading.
   - [ ] macOS 14/15 (if available): the material fallback looks right.
```
