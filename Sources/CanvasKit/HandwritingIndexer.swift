import Foundation

/// Keeps a note's `HandwritingCache` current. Watches the model (chaining its
/// `onChange`/`onStrokesChange`, so install order relative to `CanvasView`
/// doesn't matter) and, `delay` seconds after the last change, groups strokes
/// into lines and recognizes only lines whose digest has no cached text, one
/// at a time. A change mid-pass abandons the pass (finished lines are kept)
/// and the next one picks up from there. Does nothing without a recognizer.
@MainActor
public final class HandwritingIndexer {
    public let model: CanvasModel
    public let recognizer: HandwritingRecognizer?
    public var delay: TimeInterval
    /// Current results; nil until the first pass finds ink (or after a version drop).
    public private(set) var cache: HandwritingCache?
    /// Called on the main actor whenever `cache` changes.
    public var onUpdate: ((HandwritingCache) -> Void)?

    /// Text by line digest: the cache's entries plus lines finished by abandoned passes.
    private var texts: [String: String] = [:]
    private var generation = 0
    private var timer: Task<Void, Never>?
    private var pass: Task<Void, Never>?
    private var isStopped = false

    /// `cache` is the note's stored cache; dropped if its version is stale.
    /// Schedules a first pass (lines the cache lacks are recognized).
    public init(model: CanvasModel, recognizer: HandwritingRecognizer?, cache: HandwritingCache?, delay: TimeInterval = 1) {
        self.model = model
        self.recognizer = recognizer
        self.delay = delay
        guard let recognizer else {
            self.cache = cache
            return
        }
        if let cache, cache.recognitionVersion == type(of: recognizer).version {
            self.cache = cache
            for line in cache.lines { texts[line.digest] = line.text }
        }
        let previous = model.onChange
        model.onChange = { [weak self] rect in
            previous?(rect)
            MainActor.assumeIsolated { self?.modelDidChange() }
        }
        let previousStrokes = model.onStrokesChange
        model.onStrokesChange = { [weak self] ids in
            previousStrokes?(ids)
            MainActor.assumeIsolated { self?.modelDidChange() }
        }
        schedule()
    }

    /// Stops watching and abandons pending work (the chained hooks become no-ops).
    public func stop() {
        isStopped = true
        generation &+= 1
        timer?.cancel()
        timer = nil
    }

    /// Recognizes now instead of after the debounce, returning once the cache
    /// reflects the model (re-running if the model changed meanwhile).
    public func flushNow() async {
        guard recognizer != nil, !isStopped else { return }
        var current: Int
        repeat {
            timer?.cancel()
            timer = nil
            current = generation
            await startPass().value
        } while current != generation && !isStopped
    }

    // MARK: Scheduling

    private func modelDidChange() {
        guard !isStopped else { return }
        generation &+= 1
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        let nanoseconds = UInt64(max(delay, 0) * 1_000_000_000)
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            _ = self.startPass()
        }
    }

    /// Passes run one after another, each after the previous finishes.
    private func startPass() -> Task<Void, Never> {
        let previous = pass
        let current = generation
        let task = Task { [weak self] in
            await previous?.value
            await self?.run(generation: current)
        }
        pass = task
        return task
    }

    // MARK: Pass

    private func run(generation current: Int) async {
        guard let recognizer, current == generation else { return }
        let version = type(of: recognizer).version
        if let cache, cache.recognitionVersion != version {
            self.cache = nil
            texts = [:]
        }
        let strokes = model.strokes
        let lines = await Task.detached(priority: .utility) {
            let byID = Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, $0) })
            return HandwritingLines.group(strokes).map { line in
                let lineStrokes = line.strokeIDs.compactMap { byID[$0] }
                return (line: line, strokes: lineStrokes, digest: HandwritingCache.digest(of: lineStrokes))
            }
        }.value
        guard current == generation else { return }

        for item in lines where texts[item.digest] == nil {
            let text = await recognizer.text(for: item.strokes)
            // Valid for this digest even if the model moved on; "" so it isn't retried.
            texts[item.digest] = text ?? ""
            guard current == generation else { return }
        }

        let digests = Set(lines.map(\.digest))
        texts = texts.filter { digests.contains($0.key) }
        if lines.isEmpty && cache == nil { return }
        let updated = HandwritingCache(recognitionVersion: version, lines: lines.map {
            .init(digest: $0.digest, strokeIDs: $0.line.strokeIDs, bounds: $0.line.bounds, text: texts[$0.digest] ?? "")
        })
        guard updated != cache else { return }
        cache = updated
        onUpdate?(updated)
    }
}
