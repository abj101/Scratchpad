import SwiftUI
import CanvasKit

/// Search and browse the note library, shown from the band's folder button.
/// Drag a row onto a folder to move it in, onto a note to place it before that note (in that note's
/// folder), or onto the empty space to move it to the top level.
struct LibraryPopover: View {
    @ObservedObject var appState: AppState
    @ObservedObject var library: NoteLibrary
    @State private var query = ""
    @State private var sort: LibrarySort = .name
    @State private var target: DropTarget?
    /// Clicked rows; click, ⇧-click or ⌘-click like Finder. A lone note opens as it is selected.
    @State private var selection: Set<URL> = []
    @State private var editingURL: URL?
    @State private var rename = ""
    @FocusState private var renameFocused: Bool
    /// Manual order as paths, newest placement wins. ponytail: paths go stale on rename/move (item
    /// then sorts last); key by a stable id if that matters.
    @AppStorage("libraryOrder") private var order = ""

    private enum LibrarySort: String, CaseIterable { case name = "Name", recent = "Recent", custom = "Custom" }

    var body: some View {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort")
            }
            Group {
                if search.isEmpty {
                    List(sorted(library.items), children: \.children, selection: $selection) { row($0) }
                        .dropDestination(for: URL.self) { urls, _ in drop(urls, into: nil) } isTargeted: { on in
                            // A row under the pointer wins over the list behind it.
                            if on { if target == nil { target = .root } } else if target == .root { target = nil }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                                .opacity(target == .root ? 1 : 0).allowsHitTesting(false)
                        }
                } else {
                    List(library.search(search), selection: $selection) { row($0) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .transition(.opacity)
        }
        .padding(12)
        .frame(width: 300, height: 380)
        .animation(.easeOut(duration: 0.12), value: target)
        .animation(.easeInOut(duration: 0.15), value: search.isEmpty)
        .onDisappear { clickMonitor.map(NSEvent.removeMonitor); clickMonitor = nil }
        .onChange(of: selection) { _, picked in
            if picked.count == 1, let url = picked.first, AppState.isNote(url), !isOpen(url) { _ = appState.open(url) }
        }
        .onChange(of: renameFocused) { wasFocused, focused in
            if wasFocused && !focused { finishRename() }
        }
        .onAppear {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                if clickedEmptySpace(event) { selection = [] }
                return event
            }
            // The list is already populated; a rescan must not animate rows into place.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { library.reload() }
        }
    }

    @State private var clickMonitor: Any?

    /// A click outside the library panel, or on the list's blank space (below the rows).
    private func clickedEmptySpace(_ event: NSEvent) -> Bool {
        guard let window = event.window, window is NSPanel else { return true }
        var view = window.contentView?.hitTest(event.locationInWindow)
        while let current = view, !(current is NSTableView) { view = current.superview }
        guard let table = view as? NSTableView else { return false }
        return table.row(at: table.convert(event.locationInWindow, from: nil)) < 0
    }

    /// Where a drag in progress would land: into a folder, before a note, or at the top level.
    private enum DropTarget: Equatable { case into(URL), before(URL), root }

    private func row(_ item: NoteItem) -> some View {
        let isFolder = item.kind == .folder
        let here: DropTarget = isFolder ? .into(item.url) : .before(item.url)
        return HStack {
            Image(systemName: isFolder ? "folder" : "note.text")
                .font(.body)
                .frame(width: 16, height: 20)
            if editingURL == item.url {
                TextField(item.name, text: $rename)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { finishRename() }
                    .onExitCommand { cancelRename() }
                    .onAppear { renameFocused = true }
                    .accessibilityLabel("Rename \(item.name)")
                    .font(.body)
                    .frame(height: 20)
            } else {
                Text(item.name)
                    .font(.body.weight(isOpen(item.url) ? .semibold : .regular))
                    .frame(height: 20)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
                .frame(width: 12, height: 20)
                .opacity(isOpen(item.url) ? 1 : 0)
        }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { beginRename(item) }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(target == here && isFolder ? 0.25 : 0)))
            .overlay(alignment: .top) {
                Capsule().fill(Color.accentColor).frame(height: 2).opacity(target == here && !isFolder ? 1 : 0)
            }
            .draggable(item.url) {
                // A compact chip, so the lifted row doesn't smear over the names beneath it.
                Label(item.name, systemImage: isFolder ? "folder" : "note.text")
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            .dropDestination(for: URL.self) { urls, _ in
                target = nil
                return isFolder ? drop(urls, into: item.url) : drop(urls, before: item)
            } isTargeted: { on in
                if on { target = here } else if target == here { target = nil }
            }
            .contextMenu {
                Button("Rename") { beginRename(item) }
                Button("Show in Finder") { appState.showInFinder(item.url) }
                Divider()
                Button("Move to Trash") {
                    for url in selection.contains(item.url) ? Array(selection) : [item.url] { appState.trash(url) }
                    selection = []
                }
            }
    }

    private func beginRename(_ item: NoteItem) {
        editingURL = item.url
        rename = item.name
        renameFocused = true
    }

    private func finishRename() {
        guard let url = editingURL else { return }
        let name = rename.trimmingCharacters(in: .whitespacesAndNewlines)
        editingURL = nil
        renameFocused = false
        if !name.isEmpty, name != AppState.noteName(url) { appState.rename(url, to: name) }
    }

    private func cancelRename() {
        editingURL = nil
        renameFocused = false
    }

    private func isOpen(_ url: URL) -> Bool {
        appState.session.map { AppState.samePath($0.url, url) } ?? false
    }

    private func drop(_ urls: [URL], into folder: URL?) -> Bool {
        for url in urls { appState.move(url, into: folder) }
        return !urls.isEmpty
    }

    /// Moves into the target's folder if needed, then records the new position and switches to Custom.
    private func drop(_ urls: [URL], before target: NoteItem) -> Bool {
        let parent = target.url.deletingLastPathComponent()
        let folder = AppState.samePath(parent, library.root) ? nil : parent
        var paths = order.split(separator: "\n").map(String.init)
        for url in urls where !AppState.samePath(url, target.url) {
            appState.move(url, into: folder)
            let moved = parent.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            paths.removeAll { $0 == moved.standardizedFileURL.path }
            let at = paths.firstIndex(of: target.url.standardizedFileURL.path) ?? paths.endIndex
            paths.insert(moved.standardizedFileURL.path, at: at)
        }
        order = paths.joined(separator: "\n")
        sort = .custom
        return !urls.isEmpty
    }

    /// Folders first, then by the chosen order; applied to every level.
    private func sorted(_ items: [NoteItem]) -> [NoteItem] {
        let paths = order.split(separator: "\n").map(String.init)
        func rank(_ item: NoteItem) -> Int { paths.firstIndex(of: item.url.standardizedFileURL.path) ?? .max }
        return items.sorted { a, b in
            if a.kind != b.kind { return a.kind == .folder }
            switch sort {
            case .name: break
            case .recent: if a.modified != b.modified { return a.modified > b.modified }
            case .custom: if rank(a) != rank(b) { return rank(a) < rank(b) }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }.map { item in
            var item = item
            item.children = item.children.map { sorted($0) }
            return item
        }
    }
}
