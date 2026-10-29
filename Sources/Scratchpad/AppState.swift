import SwiftUI
import Combine
import CanvasKit

// MARK: - Session

/// One open note: its model, autosaver and the canvas currently showing it.
final class NoteSession {
    let id = UUID()
    var url: URL
    let model: CanvasModel
    let autosaver: NoteAutosaver
    let initialViewport: Viewport?
    /// Missing layout values on older files continue to open as canvas notes.
    var layout: NoteLayout { model.effectiveLayout }
    var scrollViews: [NoteLayout: CanvasScrollView] = [:]
    weak var scrollView: CanvasScrollView? {
        didSet {
            if let scrollView { scrollViews[scrollView.canvasView.layout] = scrollView }
            scrollView?.canvasView.handwritingIndexer = indexer
            scrollView?.canvasView.onDocumentEdit = { [weak self] in
                self?.autosaver.markDirty()
                self?.onDocumentEdit?()
            }
        }
    }
    /// Called after document-body text changes; the app debounces the title update.
    var onDocumentEdit: (() -> Void)?
    /// Keeps the note's recognized handwriting current.
    let indexer: HandwritingIndexer

    init(url: URL, document: NoteDocument) {
        self.url = url
        self.initialViewport = document.viewport
        let model = document.makeModel()
        self.model = model
        let indexer = MainActor.assumeIsolated {
            HandwritingIndexer(model: model, recognizer: HandwritingRecognizers.system(), cache: document.handwriting)
        }
        self.indexer = indexer
        self.autosaver = NoteAutosaver(model: model, url: url, lastSavedViewport: document.viewport)
        autosaver.viewportProvider = { [weak self] in self?.scrollView?.viewport }
        autosaver.beforeSnapshot = { [weak self] in self?.scrollView?.canvasView.syncDocumentBody() }
        autosaver.namedByUser = NoteTitle.isNamedByUser(document, currentName: url.deletingPathExtension().lastPathComponent)
        autosaver.automaticName = document.automaticName
        // Restore this, or a semantic name loses its meaning on every launch: the
        // next edit renames to the first line and leaving re-asks the model.
        autosaver.semanticDigest = document.semanticDigest
        autosaver.handwriting = MainActor.assumeIsolated { indexer.cache }
    }

    /// Called after the note's recognized handwriting changed and was queued for saving.
    var onHandwriting: (() -> Void)? {
        didSet {
            MainActor.assumeIsolated {
                indexer.onUpdate = { [weak self] cache in
                    guard let self else { return }
                    autosaver.handwriting = cache
                    autosaver.markDirty()
                    onHandwriting?()
                }
            }
        }
    }

    /// Stops recognizing; the session is closing.
    func stopIndexing() { MainActor.assumeIsolated { indexer.stop() } }

    /// The recognized handwriting so far.
    var handwriting: HandwritingCache? { MainActor.assumeIsolated { indexer.cache } }

    /// Named from its first line until the user renames it.
    var hasAutomaticTitle: Bool { autosaver.namedByUser != true }

    var name: String { url.deletingPathExtension().lastPathComponent }

    /// Commit any text draft into the model, then write pending changes.
    func flush() {
        scrollView?.canvasView.finishEditing(restoreFocus: false)
        autosaver.flush()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var flush: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SummonStatusItem.install()
        SummonShortcut.register()
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Summon.keepFront() }
            }
        }
    }
    /// Closing the note puts it away (see `CloseToHide`); the app stays up for the menu bar icon and shortcut.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Clicking the Dock icon with the note put away brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = Summon.window { Summon.show(window) }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { Self.flush?() }
}

// MARK: - App state

/// Library, the open note's session, and every file operation the UI offers.
final class AppState: ObservableObject {
    let canvasHandle = CanvasHandle()
    let library: NoteLibrary
    @Published private(set) var session: NoteSession?
    @Published var errorMessage: String?
    /// On-device model naming (macOS 26+); nil where the framework is missing.
    let namer = NoteNamers.system()
    /// Ask the model to name automatically named notes when the user leaves them.
    @Published var renameAutomatically: Bool {
        didSet { UserDefaults.standard.set(renameAutomatically, forKey: Self.renameAutomaticallyKey) }
    }
    private static let renameAutomaticallyKey = "naming.renameAutomatically"
    /// Requests in flight, keyed by note path and text digest.
    private var namingInFlight = Set<String>()
    /// Pending debounced first-line title refresh for live document-body edits.
    private var titleUpdateWork: DispatchWorkItem?

    private let settingsPersistence: SettingsPersistence
    private var cancellables = Set<AnyCancellable>()
    private var layoutCancellable: AnyCancellable?
    private var started = false

    init() {
        settingsPersistence = SettingsPersistence(settings: canvasHandle.settings)
        renameAutomatically = UserDefaults.standard.object(forKey: Self.renameAutomaticallyKey) as? Bool ?? true
        var startupError: Error?
        do {
            library = try NoteLibrary()
        } catch {
            startupError = error
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("Scratchpad Notes")
            library = try! NoteLibrary(root: fallback, defaults: UserDefaults(suiteName: "scratchpad.fallback") ?? .standard)
        }
        if let startupError {
            errorMessage = "Couldn't open your notes folder, so a temporary one is in use. \(Self.describe(startupError))"
        }
    }

    // MARK: Lifecycle

    /// Idempotent; called once the first window appears.
    func start() {
        guard !started else { return }
        started = true
        AppDelegate.flush = { [weak self] in self?.flush() }

        let center = NotificationCenter.default
        center.publisher(for: NSApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.flush(); self?.nameOnLeave() }.store(in: &cancellables)
        center.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.flush() }.store(in: &cancellables)
        center.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] _ in self?.flush() }.store(in: &cancellables)
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.library.reload() }.store(in: &cancellables)

        openInitialNote()
    }

    private func openInitialNote() {
        var candidates = library.recents
        if let last = library.lastOpenedNote { candidates.insert(last, at: 0) }
        for url in candidates where open(url) { return }
        createNote(in: nil)
    }

    func flush() { session?.flush() }

    /// Converts the open note as one undoable model edit.
    func convertCurrentNote(to layout: NoteLayout) {
        guard let session, session.layout != layout else { return }
        let canvas = session.scrollView?.canvasView
        if session.layout == .document {
            canvas?.syncDocumentBody()
        } else {
            canvas?.finishEditing(restoreFocus: false)
        }
        let width = session.scrollView?.contentView.bounds.width ?? 560
        let snapshot = layout == .canvas
            ? NoteConversion.canvasSnapshot(from: session.model)
            : NoteConversion.documentSnapshot(from: session.model, viewportWidth: width)
        session.model.replaceContents(with: snapshot, actionName: layout == .canvas ? "Convert to Canvas" : "Convert to Document")
        canvasHandle.settings.tool = layout == .document ? .pointer : .pen
        session.autosaver.markDirty()
    }

    // MARK: Opening

    @discardableResult
    func open(_ url: URL) -> Bool {
        if let session, Self.samePath(session.url, url) { return true }
        let document: NoteDocument
        do {
            document = try NotePackage.read(from: url)
        } catch {
            fail("Couldn't open \u{201C}\(Self.noteName(url))\u{201D}.", error)
            return false
        }
        closeSession(flush: true)
        let new = NoteSession(url: url, document: document)
        // After the event that closed the undo group, so a rename never runs mid-edit.
        new.onHandwriting = { [weak self] in self?.updateAutomaticTitle() }
        new.onDocumentEdit = { [weak self] in self?.scheduleTitleUpdate() }
        new.autosaver.onEdit = { [weak self] in DispatchQueue.main.async { self?.updateAutomaticTitle() } }
        session = new
        layoutCancellable = new.model.$layout.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        canvasHandle.settings.tool = new.layout == .document ? .pointer : .pen
        DispatchQueue.main.async { [weak self] in self?.updateAutomaticTitle() } // older notes, edits made elsewhere
        library.noteOpened(url)
        return true
    }

    private func closeSession(flush: Bool) {
        titleUpdateWork?.cancel()
        titleUpdateWork = nil
        guard let old = session else { return }
        if flush {
            old.flush()
            nameOnLeave()
            old.autosaver.close()
        } else {
            // Trashed: drop everything, including a text draft, without writing.
            old.autosaver.discard()
        }
        old.stopIndexing()
        session = nil
    }

    // MARK: Creating

    /// Creates a note (in `folder`, nil = library root) and opens it.
    func createNote(in folder: URL?) {
        do {
            let url = try library.createNote(in: folder)
            try NotePackage.write(NoteDocument(layout: canvasHandle.settings.defaultLayout), to: url)
            open(url)
        } catch {
            fail("Couldn't create a note.", error)
        }
    }

    /// Folder to create new items in: the open note's folder, nil at the root.
    var currentFolder: URL? {
        guard let session else { return nil }
        let parent = session.url.deletingLastPathComponent()
        return Self.samePath(parent, library.root) ? nil : parent
    }

    // MARK: Renaming, moving, trashing

    /// A rename by the user: the note stops being named automatically.
    func rename(_ url: URL, to name: String) {
        if affectsSession(url) { session?.flush() }
        do {
            let new = try library.rename(url, to: name)
            remapSession(from: url, to: new)
            if Self.isNote(new) { markNamedByUser(new) }
        } catch {
            fail("Couldn't rename \u{201C}\(Self.noteName(url))\u{201D}.", error)
        }
    }

    func move(_ url: URL, into folder: URL?) {
        if affectsSession(url) { session?.flush() }
        do {
            let new = try library.move(url, into: folder)
            remapSession(from: url, to: new)
        } catch {
            fail("Couldn't move \u{201C}\(Self.noteName(url))\u{201D}.", error)
        }
    }

    func trash(_ url: URL) {
        let hitsSession = affectsSession(url)
        // Write pending changes first so the trashed copy is up to date.
        if hitsSession { session?.flush() }
        do {
            try library.moveToTrash(url)
        } catch {
            fail("Couldn't move \u{201C}\(Self.noteName(url))\u{201D} to the Trash.", error)
            return
        }
        guard hitsSession else { return }
        closeSession(flush: false)
        openInitialNote()
    }

    private func markNamedByUser(_ url: URL) {
        if let session, Self.samePath(session.url, url) {
            session.autosaver.namedByUser = true
            session.autosaver.markDirty()
            return
        }
        do {
            var document = try NotePackage.read(from: url)
            guard document.namedByUser != true else { return }
            document.namedByUser = true
            try NotePackage.write(document, to: url)
        } catch {
            fail("Couldn't update \u{201C}\(Self.noteName(url))\u{201D}.", error)
        }
    }

    // MARK: Automatic titles

    /// Apple Notes-style: an automatically named note takes its first line of
    /// text as its name ("Untitled" when it has none), uniqued within its folder.
    private func updateAutomaticTitle() {
        guard let session, session.hasAutomaticTitle else { return }
        session.scrollView?.canvasView.syncDocumentBody()
        let firstLine = NoteTitle.derive(from: session.model.textBlocks, handwriting: session.handwriting)
        if session.autosaver.semanticDigest != nil {
            // Keeps its semantic name until the user leaves it with changed text.
            if firstLine != nil, namer?.isAvailable == true { return }
            session.autosaver.semanticDigest = nil
            session.autosaver.markDirty()
        }
        let base = firstLine ?? NoteTitle.defaultName
        if session.autosaver.automaticName != base || session.autosaver.namedByUser != false {
            session.autosaver.namedByUser = false
            session.autosaver.automaticName = base
            session.autosaver.markDirty()
        }
        guard !NoteTitle.matches(session.name, base: base) else { return }
        session.autosaver.flush() // not session.flush(): that would end an edit in progress
        let old = session.url
        if let new = renameUniquely(old, to: base) { remapSession(from: old, to: new) }
    }

    /// Debounced refresh for document-body typing: the body fires on every
    /// keystroke, so wait for a pause before re-deriving the title (which may
    /// rename the file). Slightly after `syncDocumentBody`'s own debounce.
    private func scheduleTitleUpdate() {
        titleUpdateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateAutomaticTitle() }
        titleUpdateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Renames to `base`, or "base 2", "base 3", ... when taken. nil on
    /// failure: the current name stays, nothing the user needs to act on.
    private func renameUniquely(_ url: URL, to base: String) -> URL? {
        if NoteTitle.matches(Self.noteName(url), base: base) { return url }
        for n in 1...100 {
            do {
                return try library.rename(url, to: n == 1 ? base : "\(base) \(n)")
            } catch NoteLibraryError.nameTaken {
                continue
            } catch {
                return nil
            }
        }
        return nil
    }

    // MARK: Semantic titles

    /// When the user leaves the open note: ask the model for a name if the
    /// note is named automatically and its text changed since the last one.
    private func nameOnLeave() {
        // Revert to the first line (or "Untitled") before semantic naming, so an
        // emptied note does not keep its last automatic name.
        updateAutomaticTitle()
        guard let session, renameAutomatically, let namer, namer.isAvailable else { return }
        session.scrollView?.canvasView.syncDocumentBody()
        let text = NoteTitle.namingText(from: session.model.textBlocks, handwriting: session.handwriting)
        guard NoteTitle.needsSemanticTitle(namedByUser: session.autosaver.namedByUser, text: text,
                                           lastDigest: session.autosaver.semanticDigest) else { return }
        requestName(text: text, url: session.url, sessionID: session.id, byUser: false)
    }

    /// "Suggest Name": names any note, including one the user named (which
    /// then stays user-named, so it never changes on its own).
    func suggestName(for url: URL) {
        guard let namer else { return }
        guard namer.isAvailable else {
            errorMessage = "Apple Intelligence isn\u{2019}t available, so Scratchpad can\u{2019}t suggest a name."
            return
        }
        let text: String
        var sessionID: UUID?
        if let session, Self.samePath(session.url, url) {
            session.flush()
            text = NoteTitle.namingText(from: session.model.textBlocks, handwriting: session.handwriting)
            sessionID = session.id
        } else {
            do {
                let document = try NotePackage.read(from: url)
                text = NoteTitle.namingText(from: document.textBlocks, handwriting: document.handwriting)
            } catch {
                fail("Couldn't read \u{201C}\(Self.noteName(url))\u{201D}.", error)
                return
            }
        }
        guard !text.isEmpty else {
            errorMessage = "\u{201C}\(Self.noteName(url))\u{201D} has no text to suggest a name from."
            return
        }
        requestName(text: text, url: url, sessionID: sessionID, byUser: true)
    }

    private func requestName(text: String, url: URL, sessionID: UUID?, byUser: Bool) {
        guard let namer else { return }
        guard NoteTitle.isNameable(text) else { // low confidence: keep the first-line title
            if byUser { errorMessage = "Couldn\u{2019}t suggest a name for \u{201C}\(Self.noteName(url))\u{201D}." }
            return
        }
        let digest = NoteTitle.digest(text)
        let key = url.standardizedFileURL.path + "\n" + digest
        guard namingInFlight.insert(key).inserted else { return }
        Task { @MainActor [weak self] in
            let title = try? await namer.suggestTitle(for: text)
            guard let self else { return }
            namingInFlight.remove(key)
            if let title {
                applyName(title, digest: digest, url: url, sessionID: sessionID, byUser: byUser)
            } else if byUser {
                errorMessage = "Couldn\u{2019}t suggest a name for \u{201C}\(Self.noteName(url))\u{201D}."
            }
        }
    }

    /// Applies a model name to the open note or, if the user moved on, to the
    /// closed note on disk. An automatic request is dropped if the text
    /// changed meanwhile or the user renamed the note.
    private func applyName(_ title: String, digest: String, url: URL, sessionID: UUID?, byUser: Bool) {
        if let session, session.id == sessionID || Self.samePath(session.url, url) {
            let current = NoteTitle.digest(NoteTitle.namingText(from: session.model.textBlocks, handwriting: session.handwriting))
            guard byUser || (session.hasAutomaticTitle && current == digest) else { return }
            if session.hasAutomaticTitle {
                session.autosaver.namedByUser = false
                session.autosaver.automaticName = title
                session.autosaver.semanticDigest = digest
                session.autosaver.markDirty()
            }
            session.autosaver.flush()
            let old = session.url
            if let new = renameUniquely(old, to: title) { remapSession(from: old, to: new) }
            return
        }
        do {
            var document = try NotePackage.read(from: url)
            let automatic = !NoteTitle.isNamedByUser(document, currentName: Self.noteName(url))
            let current = NoteTitle.digest(NoteTitle.namingText(from: document.textBlocks, handwriting: document.handwriting))
            guard byUser || (automatic && current == digest) else { return }
            if automatic {
                document.namedByUser = false
                document.automaticName = title
                document.semanticDigest = digest
                try NotePackage.write(document, to: url)
            }
            _ = renameUniquely(url, to: title)
        } catch {
            if byUser { fail("Couldn't rename \u{201C}\(Self.noteName(url))\u{201D}.", error) }
        }
    }

    private func affectsSession(_ url: URL) -> Bool {
        guard let session else { return false }
        return Self.isInside(session.url, of: url)
    }

    private func remapSession(from old: URL, to new: URL) {
        guard let session, Self.isInside(session.url, of: old) else { return }
        let oldPath = old.standardizedFileURL.path
        let rest = session.url.standardizedFileURL.path.dropFirst(oldPath.count)
        let url = URL(fileURLWithPath: new.standardizedFileURL.path + rest, isDirectory: true)
        session.url = url
        session.autosaver.url = url
        objectWillChange.send()
    }

    // MARK: Finder

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func showLibraryInFinder() {
        NSWorkspace.shared.open(library.root)
    }

    // MARK: Helpers

    func fail(_ message: String, _ error: Error) {
        errorMessage = "\(message) \(Self.describe(error))"
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case NoteLibraryError.invalidName: return "That name isn\u{2019}t allowed."
        case NoteLibraryError.nameTaken: return "An item with that name already exists."
        case NoteLibraryError.invalidMove: return "A folder can\u{2019}t be moved into itself."
        case NoteLibraryError.outsideLibrary: return "That item is outside the library."
        case NotePackageError.missingDocument: return "The note has no document."
        case NotePackageError.unsupportedVersion: return "The note was made by a newer version of Scratchpad."
        default: return error.localizedDescription
        }
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// True if `url` is `container` or lies inside it.
    static func isInside(_ url: URL, of container: URL) -> Bool {
        let path = url.standardizedFileURL.path, base = container.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    static func isNote(_ url: URL) -> Bool { url.pathExtension == NotePackage.fileExtension }

    static func noteName(_ url: URL) -> String {
        isNote(url) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }
}

/// SwiftUI also declares a `LibraryItem`; this picks CanvasKit's.
typealias NoteItem = CanvasKit.LibraryItem
