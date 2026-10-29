import AppKit
import Combine

// MARK: - Phase 5 contract
//
// A note is a package directory `Name.scratch/` holding `document.json`
// (a JSON-encoded `NoteDocument`). The library is a plain folder tree of those
// packages under `NoteLibrary.root`; folders are ordinary directories. Writes
// are atomic. Deleting goes to the Trash, never permanent removal.
// Drawing/input settings are app-wide (UserDefaults), not per note.

// MARK: Viewport

/// What part of the canvas a note was showing: world point at the viewport
/// center plus the scroll view magnification.
public struct Viewport: Codable, Equatable {
    public var center: CGPoint
    public var magnification: Double

    public init(center: CGPoint = .zero, magnification: Double = 1) {
        self.center = center; self.magnification = magnification
    }
}

// MARK: Document

/// Serializable state of one note.
public struct NoteDocument: Codable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var strokes: [Stroke]
    public var textBlocks: [TextBlock]
    public var viewport: Viewport?
    /// Missing layout values decode as nil and remain canvas notes.
    public var layout: NoteLayout?
    /// Legacy ink anchors; only present in notes saved before drawing zones.
    public var inkAnchors: [InkAnchor]?
    /// Document-mode drawing zones; absent on canvas notes and older documents.
    public var drawingZones: [DrawingZone]?
    /// True once the user renamed the note; it is then never named automatically.
    /// nil (older files): automatic only while the name is a default one.
    public var namedByUser: Bool?
    /// The base name last given automatically; a file name that no longer
    /// matches it was renamed outside the app (e.g. in Finder).
    public var automaticName: String?
    /// `NoteTitle.digest` of the naming text the language model last named the
    /// note from; non-nil means `automaticName` is a semantic name.
    public var semanticDigest: String?
    /// Recognized handwriting per line (nil: none yet, or an older file).
    public var handwriting: HandwritingCache?

    public init(strokes: [Stroke] = [], textBlocks: [TextBlock] = [], viewport: Viewport? = nil,
                layout: NoteLayout? = nil, inkAnchors: [InkAnchor]? = nil,
                drawingZones: [DrawingZone]? = nil) {
        self.version = Self.currentVersion
        self.strokes = strokes
        self.textBlocks = textBlocks
        self.viewport = viewport
        self.layout = layout
        self.inkAnchors = inkAnchors
        self.drawingZones = drawingZones
    }

    /// Snapshot of a model's current contents (value copy; cheap).
    public init(model: CanvasModel, viewport: Viewport?) {
        self.init(strokes: model.strokes, textBlocks: model.textBlocks, viewport: viewport,
                  layout: model.layout, inkAnchors: model.inkAnchors, drawingZones: model.drawingZones)
    }

    /// A fresh model holding this document's strokes and text blocks.
    public func makeModel(undoManager: UndoManager = UndoManager()) -> CanvasModel {
        CanvasModel(strokes: strokes, textBlocks: textBlocks, layout: layout, inkAnchors: inkAnchors,
                    drawingZones: drawingZones, undoManager: undoManager)
    }
}

public enum NotePackageError: Error, Equatable {
    /// The package has no `document.json`.
    case missingDocument
    /// `version` is newer than `NoteDocument.currentVersion`.
    case unsupportedVersion(Int)
}

/// Reads and writes `Name.scratch/` packages via `FileWrapper`.
public enum NotePackage {
    public static let fileExtension = "scratch"
    public static let documentFileName = "document.json"

    /// Directory wrapper containing `document.json`.
    public static func fileWrapper(for document: NoteDocument) throws -> FileWrapper {
        try fileWrapper(forEncoded: encode(document))
    }

    public static func document(from wrapper: FileWrapper) throws -> NoteDocument {
        guard let data = wrapper.fileWrappers?[documentFileName]?.regularFileContents else {
            throw NotePackageError.missingDocument
        }
        return try decode(data)
    }

    public static func read(from url: URL) throws -> NoteDocument {
        try document(from: FileWrapper(url: url, options: []))
    }

    static func encode(_ document: NoteDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    static func decode(_ data: Data) throws -> NoteDocument {
        struct Header: Decodable { var version: Int }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        if header.version > NoteDocument.currentVersion {
            throw NotePackageError.unsupportedVersion(header.version)
        }
        return try decoder.decode(NoteDocument.self, from: data)
    }

    static func fileWrapper(forEncoded data: Data) -> FileWrapper {
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = documentFileName
        return FileWrapper(directoryWithFileWrappers: [documentFileName: file])
    }

    /// Atomic write; replaces any existing package at `url`.
    public static func write(_ document: NoteDocument, to url: URL) throws {
        try write(encoded: encode(document), to: url)
    }

    static func write(encoded data: Data, to url: URL) throws {
        let original = FileManager.default.fileExists(atPath: url.path) ? url : nil
        try fileWrapper(forEncoded: data).write(to: url, options: [.atomic], originalContentsURL: original)
    }
}

// MARK: Library

public struct LibraryItem: Identifiable, Hashable {
    public enum Kind: Hashable { case folder, note }

    public var url: URL
    public var kind: Kind
    /// Display name: file name without the `.scratch` extension.
    public var name: String
    public var modified: Date
    /// Folders: sorted children (possibly empty). Notes: nil (fits `OutlineGroup`).
    public var children: [LibraryItem]?

    public var id: URL { url }

    public init(url: URL, kind: Kind, name: String, modified: Date, children: [LibraryItem]?) {
        self.url = url; self.kind = kind; self.name = name; self.modified = modified; self.children = children
    }
}

public enum NoteLibraryError: Error, Equatable {
    /// Empty/whitespace name, or it contains "/" or ":" or starts with ".".
    case invalidName
    /// The destination name is already taken (rename only; create/move pick a unique name).
    case nameTaken
    /// Moving a folder into itself or one of its descendants.
    case invalidMove
    /// The url is not inside `root`.
    case outsideLibrary
}

/// The folder tree of notes. All mutations reload `items` and keep the stored
/// recents / last-opened paths in step with renames, moves and trashing.
/// Recents and last-opened are stored in `defaults` as paths relative to `root`.
public final class NoteLibrary: ObservableObject {
    public static let maxRecents = 10
    static let recentsKey = "library.recents"
    static let lastOpenedKey = "library.lastOpened"

    public let root: URL
    /// Root's children: folders first, then notes, each sorted by
    /// `localizedStandardCompare` on name. Hidden files and non-note files are skipped.
    @Published public private(set) var items: [LibraryItem] = []
    /// Existing notes, most recently opened first, at most `maxRecents`.
    @Published public private(set) var recents: [URL] = []

    private let defaults: UserDefaults
    private let fileManager = FileManager.default

    /// `~/Library/Application Support/Scratchpad/Notes`.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scratchpad", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
    }

    /// Creates `root` if needed, then loads.
    public init(root: URL = NoteLibrary.defaultRoot, defaults: UserDefaults = .standard) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.defaults = defaults
        reload()
    }

    // MARK: Scanning

    /// Rescan the disk.
    public func reload() {
        items = scan(root)
        recents = Array(storedRecents.compactMap(existingNote).prefix(Self.maxRecents))
    }

    private func scan(_ directory: URL) -> [LibraryItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var folders: [LibraryItem] = [], notes: [LibraryItem] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            if url.pathExtension == NotePackage.fileExtension {
                notes.append(LibraryItem(url: url, kind: .note, name: url.deletingPathExtension().lastPathComponent,
                                         modified: modified, children: nil))
            } else {
                folders.append(LibraryItem(url: url, kind: .folder, name: url.lastPathComponent,
                                           modified: modified, children: scan(url)))
            }
        }
        let byName: (LibraryItem, LibraryItem) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return folders.sorted(by: byName) + notes.sorted(by: byName)
    }

    // MARK: Create

    /// Writes an empty note. Name made unique within the folder: "Untitled", "Untitled 2", ...
    /// `folder == nil` means root.
    @discardableResult
    public func createNote(in folder: URL? = nil, named name: String = "Untitled") throws -> URL {
        let parent = try resolveFolder(folder)
        let trimmed = try validated(name)
        let url = uniqueURL(in: parent, name: trimmed, isNote: true)
        try NotePackage.write(NoteDocument(), to: url)
        reload()
        return url
    }

    /// Name made unique the same way ("New Folder", "New Folder 2", ...).
    @discardableResult
    public func createFolder(in folder: URL? = nil, named name: String = "New Folder") throws -> URL {
        let parent = try resolveFolder(folder)
        let trimmed = try validated(name)
        let url = uniqueURL(in: parent, name: trimmed, isNote: false)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        reload()
        return url
    }

    // MARK: Rename / move / trash

    /// Rename a note (extension kept) or folder in place. Returns the new url;
    /// renaming to the current name is a no-op returning `url`.
    @discardableResult
    public func rename(_ url: URL, to newName: String) throws -> URL {
        let oldRel = try relativePath(of: url)
        let trimmed = try validated(newName)
        let isNote = url.pathExtension == NotePackage.fileExtension
        let current = isNote ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        if trimmed == current { return url }
        let parent = url.deletingLastPathComponent()
        let destination = parent.appendingPathComponent(isNote ? trimmed + "." + NotePackage.fileExtension : trimmed,
                                                       isDirectory: true)
        let sameItem = resolved(destination).path.lowercased() == resolved(url).path.lowercased()
        if fileManager.fileExists(atPath: destination.path), !sameItem { throw NoteLibraryError.nameTaken }
        try fileManager.moveItem(at: url, to: destination)
        rewriteStoredPaths(from: oldRel, to: try relativePath(of: destination))
        reload()
        return destination
    }

    /// Move a note or folder into `folder` (nil = root), uniquing the name.
    /// Returns the new url (or `url` if already there).
    @discardableResult
    public func move(_ url: URL, into folder: URL?) throws -> URL {
        let oldRel = try relativePath(of: url)
        let parent = try resolveFolder(folder)
        let source = resolved(url).path, target = resolved(parent).path
        let isNote = url.pathExtension == NotePackage.fileExtension
        if !isNote, target == source || target.hasPrefix(source + "/") { throw NoteLibraryError.invalidMove }
        if resolved(url.deletingLastPathComponent()).path == target { return url }
        let base = isNote ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        let destination = uniqueURL(in: parent, name: base, isNote: isNote)
        try fileManager.moveItem(at: url, to: destination)
        rewriteStoredPaths(from: oldRel, to: try relativePath(of: destination))
        reload()
        return destination
    }

    /// `FileManager.trashItem`; never a permanent delete.
    public func moveToTrash(_ url: URL) throws {
        let rel = try relativePath(of: url)
        try fileManager.trashItem(at: url, resultingItemURL: nil)
        rewriteStoredPaths(from: rel, to: nil)
        reload()
    }

    // MARK: Search

    /// Notes (flat, any depth) whose name contains `query`, case- and
    /// diacritic-insensitive, sorted by name. Empty query → [].
    public func search(_ query: String) -> [LibraryItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        func notes(in items: [LibraryItem]) -> [LibraryItem] {
            items.flatMap { $0.kind == .note ? [$0] : notes(in: $0.children ?? []) }
        }
        return notes(in: items)
            .filter { $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Recents

    /// Record that `url` was opened: moves it to the front of `recents` and
    /// sets it as the last-opened note.
    public func noteOpened(_ url: URL) {
        guard let rel = try? relativePath(of: url) else { return }
        var stored = storedRecents.filter { $0 != rel }
        stored.insert(rel, at: 0)
        defaults.set(Array(stored.prefix(Self.maxRecents * 3)), forKey: Self.recentsKey)
        defaults.set(rel, forKey: Self.lastOpenedKey)
        recents = Array(storedRecents.compactMap(existingNote).prefix(Self.maxRecents))
    }

    /// The last-opened note, if it still exists.
    public var lastOpenedNote: URL? {
        defaults.string(forKey: Self.lastOpenedKey).flatMap(existingNote)
    }

    private var storedRecents: [String] { defaults.stringArray(forKey: Self.recentsKey) ?? [] }

    private func existingNote(_ rel: String) -> URL? {
        let url = url(forRelative: rel)
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
    }

    private func url(forRelative rel: String) -> URL {
        rel.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }
    }

    /// Rewrites stored paths equal to or under `old` to `new`; `nil` drops them.
    private func rewriteStoredPaths(from old: String, to new: String?) {
        func rewrite(_ path: String) -> String? {
            if path == old { return new }
            if path.hasPrefix(old + "/") { return new.map { $0 + path.dropFirst(old.count) } }
            return path
        }
        defaults.set(storedRecents.compactMap(rewrite), forKey: Self.recentsKey)
        if let last = defaults.string(forKey: Self.lastOpenedKey) {
            if let moved = rewrite(last) {
                defaults.set(moved, forKey: Self.lastOpenedKey)
            } else {
                defaults.removeObject(forKey: Self.lastOpenedKey)
            }
        }
    }

    // MARK: Paths

    /// Symlink-resolved url; resolves the parent so not-yet-existing items still compare correctly.
    private func resolved(_ url: URL) -> URL {
        let std = url.standardizedFileURL
        if fileManager.fileExists(atPath: std.path) { return std.resolvingSymlinksInPath() }
        return std.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(std.lastPathComponent)
    }

    /// Path of `url` relative to the root; throws `.outsideLibrary` for the root itself or anything outside.
    private func relativePath(of url: URL) throws -> String {
        let prefix = resolved(root).path + "/"
        let path = resolved(url).path
        guard path.hasPrefix(prefix), path.count > prefix.count else { throw NoteLibraryError.outsideLibrary }
        return String(path.dropFirst(prefix.count))
    }

    /// `folder` (nil = root) as a directory inside the library.
    private func resolveFolder(_ folder: URL?) throws -> URL {
        guard let folder else { return root }
        if resolved(folder).path != resolved(root).path { _ = try relativePath(of: folder) }
        return folder
    }

    private func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.hasPrefix(".") else {
            throw NoteLibraryError.invalidName
        }
        return trimmed
    }

    private func uniqueURL(in parent: URL, name: String, isNote: Bool) -> URL {
        var n = 1
        while true {
            let candidate = n == 1 ? name : "\(name) \(n)"
            let url = parent.appendingPathComponent(
                isNote ? candidate + "." + NotePackage.fileExtension : candidate, isDirectory: true)
            if !fileManager.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}

// MARK: Autosave

/// Saves one note's model to its package shortly after it changes.
///
/// Changes are detected from `model.undoManager` notifications (close of an
/// undo group, undo, redo; only that manager's) plus explicit `markDirty()`.
/// A save snapshots the model on the calling (main) thread and encodes +
/// writes on a private serial queue. `flush()` is synchronous.
public final class NoteAutosaver {
    public let model: CanvasModel
    /// Destination package; update it when the note is renamed or moved.
    public var url: URL
    /// Debounce interval after the last change.
    public var delay: TimeInterval
    /// Queried at save time; the viewport is written with the document.
    public var viewportProvider: (() -> Viewport?)?
    /// Synchronize a live editor before reading model contents.
    public var beforeSnapshot: (() -> Void)?
    /// Called on the main queue if a write fails.
    public var onError: ((Error) -> Void)?
    /// True between a change and the snapshot of the save that covers it.
    public private(set) var isDirty = false
    /// Written with every save (see `NoteDocument.namedByUser`).
    public var namedByUser: Bool?
    /// Written with every save (see `NoteDocument.automaticName`).
    public var automaticName: String?
    /// Written with every save (see `NoteDocument.semanticDigest`).
    public var semanticDigest: String?
    /// Written with every save (see `NoteDocument.handwriting`).
    public var handwriting: HandwritingCache?
    /// Called on each model change (undo group closed, undo, redo), before the save is scheduled.
    public var onEdit: (() -> Void)?

    private var lastSavedViewport: Viewport?
    private var pending: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var isClosed = false
    private let queue = DispatchQueue(label: "scratchpad.autosave", qos: .utility)

    /// `lastSavedViewport` is the viewport the note was loaded with, so
    /// opening a note and closing it untouched does not rewrite it.
    public init(model: CanvasModel, url: URL, lastSavedViewport: Viewport? = nil, delay: TimeInterval = 1) {
        self.model = model
        self.url = url
        self.lastSavedViewport = lastSavedViewport
        self.delay = delay
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
        ]
        observers = names.map {
            NotificationCenter.default.addObserver(forName: $0, object: model.undoManager, queue: nil) { [weak self] _ in
                self?.onEdit?()
                self?.markDirty()
            }
        }
    }

    deinit { removeObservers() }

    // MARK: Saving

    /// Schedule a debounced save.
    public func markDirty() {
        guard !isClosed else { return }
        isDirty = true
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveInBackground() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Save now, and wait for the write, if dirty or if the viewport differs
    /// from the last saved one. Cancels any pending debounced save. Returns
    /// whether a write happened. Call before switching notes and on quit.
    @discardableResult
    public func flush() -> Bool {
        guard !isClosed else { return false }
        pending?.cancel()
        pending = nil
        beforeSnapshot?()
        let viewport = viewportProvider?()
        guard isDirty || (viewport != nil && viewport != lastSavedViewport) else { return false }
        let (document, target) = snapshot(viewport)
        var failure: Error?
        queue.sync {
            do { try NotePackage.write(document, to: target) } catch { failure = error }
        }
        if let failure {
            fail(failure)
            return false
        }
        return true
    }

    /// Stops observing; flushes first.
    public func close() {
        flush()
        isClosed = true
        removeObservers()
    }

    /// Stops observing and drops unsaved changes without writing; waits for
    /// any write already queued. Use when the note's package was trashed.
    public func discard() {
        pending?.cancel()
        pending = nil
        isClosed = true
        removeObservers()
        queue.sync {}
        isDirty = false
    }

    private func saveInBackground() {
        pending = nil
        beforeSnapshot?()
        guard isDirty || (viewportProvider?() ?? lastSavedViewport) != lastSavedViewport else { return }
        let (document, target) = snapshot(viewportProvider?())
        queue.async { [weak self] in
            do { try NotePackage.write(document, to: target) } catch { self?.fail(error) }
        }
    }

    private func snapshot(_ viewport: Viewport?) -> (NoteDocument, URL) {
        isDirty = false
        if let viewport { lastSavedViewport = viewport }
        var document = NoteDocument(model: model, viewport: viewport ?? lastSavedViewport)
        document.namedByUser = namedByUser
        document.automaticName = automaticName
        document.semanticDigest = semanticDigest
        document.handwriting = handwriting
        return (document, url)
    }

    private func fail(_ error: Error) {
        let report = { [weak self] in
            guard let self else { return }
            isDirty = true
            onError?(error)
        }
        if Thread.isMainThread { report() } else { DispatchQueue.main.async(execute: report) }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

// MARK: Settings persistence

/// Loads `CanvasSettings` from `defaults` on init, then writes every change
/// back. Keys are `settings.<property>`. Persists tool, color, savedColors, width,
/// eraserRadius, inputMode, penKey, activation. A stored
/// `.tablet` or `.write` input mode loads as `.pen` (never start with the cursor locked).
/// Missing or undecodable values keep the settings' current values.
public final class SettingsPersistence {
    private var cancellables: Set<AnyCancellable> = []

    public init(settings: CanvasSettings, defaults: UserDefaults = .standard) {
        func key(_ name: String) -> String { "settings.\(name)" }
        func raw<T: RawRepresentable>(_ name: String, as _: T.Type) -> T? where T.RawValue == String {
            defaults.string(forKey: key(name)).flatMap(T.init(rawValue:))
        }
        func number(_ name: String) -> Double? { defaults.object(forKey: key(name)) as? Double }

        if let v = raw("tool", as: Tool.self) { settings.tool = v }
        if let data = defaults.data(forKey: key("color")),
           let v = try? JSONDecoder().decode(RGBA.self, from: data) { settings.color = v }
        if let data = defaults.data(forKey: key("savedColors")),
           let slots = try? JSONDecoder().decode([RGBA?].self, from: data),
           slots.count == CanvasSettings.savedColorSlotCount { settings.savedColors = slots }
        if let data = defaults.data(forKey: key("backgroundColor")),
           let v = try? JSONDecoder().decode(RGBA.self, from: data) { settings.backgroundColor = v }
        if let v = number("width") { settings.width = v }
        if let v = number("scribeDefaultWidth"), v.isFinite, CanvasSettings.widthRange.contains(v) {
            settings.scribeDefaultWidth = v
        }
        settings.unifyScribeWidth = defaults.bool(forKey: key("unifyScribeWidth"))
        if let v = number("defaultFontSize"), v.isFinite, CanvasSettings.fontSizeRange.contains(v) {
            settings.defaultFontSize = v
        }
        if let v = number("eraserRadius") { settings.eraserRadius = v }
        if let v = raw("inputMode", as: InputMode.self) { settings.inputMode = v.usesTabletInput ? .pen : v }
        if let v = raw("penKey", as: PenKey.self) { settings.penKey = v }
        if let v = raw("activation", as: PenActivation.self) { settings.activation = v }
        if let v = raw("writingPanelPlacement", as: WritingPanelPlacement.self) { settings.writingPanelPlacement = v }
        if defaults.object(forKey: key("showTextOptionsWhileEditing")) != nil { settings.showTextOptionsWhileEditing = defaults.bool(forKey: key("showTextOptionsWhileEditing")) }
        if defaults.object(forKey: key("scribeSentencePolish2")) != nil { settings.scribeSentencePolish = defaults.bool(forKey: key("scribeSentencePolish2")) }
        settings.scribeMath = defaults.bool(forKey: key("scribeMath"))
        if defaults.object(forKey: key("autoCloseBrackets")) != nil { settings.autoCloseBrackets = defaults.bool(forKey: key("autoCloseBrackets")) }
        if defaults.object(forKey: key("handwritingToText")) != nil { settings.handwritingToText = defaults.bool(forKey: key("handwritingToText")) }
        settings.$tool.dropFirst().sink { defaults.set($0.rawValue, forKey: key("tool")) }.store(in: &cancellables)
        settings.$color.dropFirst().sink {
            if let data = try? JSONEncoder().encode($0) { defaults.set(data, forKey: key("color")) }
        }.store(in: &cancellables)
        settings.$savedColors.dropFirst().sink {
            if let data = try? JSONEncoder().encode($0) { defaults.set(data, forKey: key("savedColors")) }
        }.store(in: &cancellables)
        settings.$backgroundColor.dropFirst().sink {
            if let data = try? JSONEncoder().encode($0) { defaults.set(data, forKey: key("backgroundColor")) }
        }.store(in: &cancellables)
        settings.$width.dropFirst().sink { defaults.set($0, forKey: key("width")) }.store(in: &cancellables)
        settings.$scribeDefaultWidth.dropFirst().sink { defaults.set($0, forKey: key("scribeDefaultWidth")) }.store(in: &cancellables)
        settings.$unifyScribeWidth.dropFirst().sink { defaults.set($0, forKey: key("unifyScribeWidth")) }.store(in: &cancellables)
        settings.$defaultFontSize.dropFirst().sink {
            defaults.set(CanvasSettings.canonicalFontSize($0), forKey: key("defaultFontSize"))
        }.store(in: &cancellables)
        settings.$eraserRadius.dropFirst().sink { defaults.set($0, forKey: key("eraserRadius")) }.store(in: &cancellables)
        settings.$inputMode.dropFirst().sink { defaults.set($0.rawValue, forKey: key("inputMode")) }.store(in: &cancellables)
        settings.$penKey.dropFirst().sink { defaults.set($0.rawValue, forKey: key("penKey")) }.store(in: &cancellables)
        settings.$activation.dropFirst().sink { defaults.set($0.rawValue, forKey: key("activation")) }.store(in: &cancellables)
        settings.$writingPanelPlacement.dropFirst().sink { defaults.set($0.rawValue, forKey: key("writingPanelPlacement")) }.store(in: &cancellables)
        settings.$showTextOptionsWhileEditing.dropFirst().sink { defaults.set($0, forKey: key("showTextOptionsWhileEditing")) }.store(in: &cancellables)
        settings.$scribeSentencePolish.dropFirst().sink { defaults.set($0, forKey: key("scribeSentencePolish2")) }.store(in: &cancellables)
        settings.$autoCloseBrackets.dropFirst().sink { defaults.set($0, forKey: key("autoCloseBrackets")) }.store(in: &cancellables)
        settings.$scribeMath.dropFirst().sink { defaults.set($0, forKey: key("scribeMath")) }.store(in: &cancellables)
        settings.$handwritingToText.dropFirst().sink { defaults.set($0, forKey: key("handwritingToText")) }.store(in: &cancellables)
        if let v = raw("defaultLayout", as: NoteLayout.self) { settings.defaultLayout = v }
        settings.$defaultLayout.dropFirst().sink { defaults.set($0.rawValue, forKey: key("defaultLayout")) }.store(in: &cancellables)
    }
}
