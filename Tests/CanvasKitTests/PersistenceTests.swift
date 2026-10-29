import XCTest
import AppKit
@testable import CanvasKit

final class PersistenceTests: XCTestCase {

    // MARK: - NoteDocument tests

    func testNoteDocumentInitWithDefaultVersion() throws {
        let doc = NoteDocument(strokes: [], textBlocks: [], viewport: nil)
        XCTAssertEqual(doc.version, NoteDocument.currentVersion)
    }

    func testNoteDocumentInitFromModel() throws {
        let model = CanvasModel()
        let stroke = Stroke(
            id: UUID(),
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
            color: .blue,
            width: 2.5
        )
        model.add(stroke)

        let viewport = Viewport(center: CGPoint(x: 5, y: 5), magnification: 2)
        let doc = NoteDocument(model: model, viewport: viewport)

        XCTAssertEqual(doc.version, NoteDocument.currentVersion)
        XCTAssertEqual(doc.strokes.count, 1)
        XCTAssertEqual(doc.strokes[0].id, stroke.id)
        XCTAssertEqual(doc.viewport, viewport)
    }

    func testNoteDocumentMakeModel() throws {
        let stroke = Stroke(
            id: UUID(),
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
            color: .red,
            width: 3
        )
        let doc = NoteDocument(strokes: [stroke], textBlocks: [], viewport: nil)

        let model = doc.makeModel()
        XCTAssertEqual(model.strokes.count, 1)
        XCTAssertEqual(model.strokes[0].id, stroke.id)
        XCTAssertEqual(model.strokes[0].color, .red)
        XCTAssertEqual(model.strokes[0].width, 3)
    }

    func testNoteDocumentRoundTripJSON() throws {
        let stroke = Stroke(
            id: UUID(),
            points: [StrokePoint(x: 1, y: 2, t: 0.1), StrokePoint(x: 3, y: 4, t: 0.2)],
            color: .green,
            width: 1.5
        )
        let viewport = Viewport(center: CGPoint(x: 100, y: 200), magnification: 1.5)
        let original = NoteDocument(strokes: [stroke], textBlocks: [], viewport: viewport)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NoteDocument.self, from: encoded)

        XCTAssertEqual(decoded.version, NoteDocument.currentVersion)
        XCTAssertEqual(decoded.strokes.count, 1)
        XCTAssertEqual(decoded.strokes[0].id, stroke.id)
        XCTAssertEqual(decoded.viewport, viewport)
    }

    func testNoteDocumentLayoutAndInkAnchorsRoundTrip() throws {
        let strokeID = UUID()
        let anchor = InkAnchor(strokeIDs: [strokeID], kind: .glyph, charIndex: 4, offset: CGVector(dx: 3, dy: -2))
        let original = NoteDocument(strokes: [], textBlocks: [], layout: .document, inkAnchors: [anchor])
        let decoded = try JSONDecoder().decode(NoteDocument.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded.layout, .document)
        XCTAssertEqual(decoded.inkAnchors, [anchor])
        XCTAssertEqual(decoded.makeModel().layout, .document)
        XCTAssertEqual(decoded.makeModel().inkAnchors, [anchor])
    }

    func testOlderNoteWithoutLayoutRemainsCanvas() throws {
        let data = Data(#"{"version":1,"strokes":[],"textBlocks":[]}"#.utf8)
        let document = try JSONDecoder().decode(NoteDocument.self, from: data)

        XCTAssertNil(document.layout)
        XCTAssertEqual(document.makeModel().effectiveLayout, .canvas)
    }

    func testNoteDocumentWithTextBlocksRoundTrip() throws {
        let textString = NSAttributedString(string: "Hello World", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.blue
        ])
        let textContent = TextBlock.content(from: textString)
        let textBlock = TextBlock(id: UUID(), origin: CGPoint(x: 10, y: 20), width: 100, height: 30, content: textContent)

        let doc = NoteDocument(strokes: [], textBlocks: [textBlock], viewport: nil)
        let encoded = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(NoteDocument.self, from: encoded)

        XCTAssertEqual(decoded.textBlocks.count, 1)
        XCTAssertEqual(decoded.textBlocks[0].id, textBlock.id)
        XCTAssertEqual(decoded.textBlocks[0].origin, CGPoint(x: 10, y: 20))
        XCTAssertEqual(decoded.textBlocks[0].width, 100)
    }

    func testNoteDocumentTextBlockAttributesPreserve() throws {
        let boldFont = NSFont.boldSystemFont(ofSize: 14)
        let redColor = NSColor.red
        let textString = NSMutableAttributedString(string: "Bold Red Text")
        textString.setAttributes([.font: boldFont, .foregroundColor: redColor], range: NSRange(location: 0, length: 4))

        let textContent = TextBlock.content(from: textString)
        let textBlock = TextBlock(id: UUID(), origin: .zero, width: 100, height: 30, content: textContent)
        let doc = NoteDocument(strokes: [], textBlocks: [textBlock], viewport: nil)

        let encoded = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(NoteDocument.self, from: encoded)
        let decodedString = decoded.textBlocks[0].attributedString

        XCTAssertEqual(decodedString.string, "Bold Red Text")

        let attrs = decodedString.attributes(at: 0, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)

        let color = attrs[.foregroundColor] as? NSColor
        let redSRGB = NSColor.red.usingColorSpace(.sRGB) ?? NSColor.red
        guard let colorSRGB = color?.usingColorSpace(.sRGB) ?? color else { return }
        XCTAssertEqual(colorSRGB.redComponent, redSRGB.redComponent, accuracy: 0.01)
        XCTAssertEqual(colorSRGB.greenComponent, redSRGB.greenComponent, accuracy: 0.01)
        XCTAssertEqual(colorSRGB.blueComponent, redSRGB.blueComponent, accuracy: 0.01)
    }

    func testEquationAttachmentSecureArchiveRoundTrip() throws {
        let previewSource = NSView(frame: CGRect(x: 0, y: 0, width: 48, height: 30))
        let preview = previewSource.dataWithPDF(inside: previewSource.bounds)
        let equation = EquationAttachment(latex: #"\frac{x_1}{y^2}"#, fontSize: 18,
                                          previewPDF: preview,
                                          previewMetrics: .init(width: 48, height: 30, baseline: 20))
        let string = NSMutableAttributedString(string: "before ")
        string.append(NSAttributedString(attachment: equation))
        string.append(NSAttributedString(string: " after"))
        let archive = try NSKeyedArchiver.archivedData(withRootObject: string, requiringSecureCoding: true)
        let block = TextBlock(origin: .zero, content: archive)

        let decoded = block.attributedString
        let range = NSRange(location: 0, length: decoded.length)
        var found: EquationAttachment?
        decoded.enumerateAttribute(.attachment, in: range) { value, _, _ in
            if let equation = value as? EquationAttachment { found = equation }
        }

        XCTAssertEqual(found?.id, equation.id)
        XCTAssertEqual(found?.latex, equation.latex)
        XCTAssertEqual(found?.fontSize, equation.fontSize)
        XCTAssertEqual(found?.previewPDF, equation.previewPDF)
        XCTAssertEqual(found?.previewMetrics, equation.previewMetrics)
    }

    func testSavedNoteReopensMultipleEditableEquations() throws {
        let first = EquationAttachment(latex: #"\frac{x}{y}"#, fontSize: 16)
        let second = EquationAttachment(latex: #"\alpha^{2}"#, fontSize: 18)
        let content = NSMutableAttributedString(string: "Result: ")
        content.append(NSAttributedString(attachment: first))
        content.append(NSAttributedString(string: " + "))
        content.append(NSAttributedString(attachment: second))
        let block = TextBlock(origin: .zero, width: 300, content: TextBlock.content(from: content))
        let document = NoteDocument(textBlocks: [block], layout: .document)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("equation-reopen-\(UUID().uuidString).scratch", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: url) }

        try NotePackage.write(document, to: url)
        let reopened = try NotePackage.read(from: url)
        let reopenedText = try XCTUnwrap(reopened.textBlocks.first).attributedString
        var equations: [EquationAttachment] = []
        reopenedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: reopenedText.length)) {
            value, _, _ in
            if let equation = value as? EquationAttachment { equations.append(equation) }
        }

        XCTAssertEqual(reopened.version, 2)
        XCTAssertEqual(equations.map(\.id), [first.id, second.id])
        XCTAssertEqual(equations.map(\.latex), [first.latex, second.latex])
    }

    func testNoteVersionBumpedForEquationAttachmentCompatibility() {
        XCTAssertEqual(NoteDocument.currentVersion, 2)
        XCTAssertEqual(NoteDocument().version, 2)
    }

    func testCorruptPreviewFallsBackToSourceAndMetricsStayFinite() throws {
        let attachment = EquationAttachment(latex: #"\sqrt{x}"#, fontSize: .greatestFiniteMagnitude,
                                            previewPDF: Data("not a PDF".utf8),
                                            previewMetrics: .init(width: .infinity, height: -20, baseline: .nan))
        XCTAssertNotNil(attachment.image)
        XCTAssertTrue(attachment.bounds.origin.x.isFinite && attachment.bounds.origin.y.isFinite)
        XCTAssertTrue(attachment.bounds.width.isFinite && attachment.bounds.height.isFinite)
        XCTAssertEqual(attachment.fontSize, 512)
        XCTAssertEqual(attachment.previewMetrics?.width, 1)
        XCTAssertEqual(attachment.previewMetrics?.height, 1)
        XCTAssertEqual(attachment.previewMetrics?.baseline, 1)
        XCTAssertGreaterThan(attachment.bounds.width, 1, "Source fallback must not use corrupt preview geometry")

        let preview = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 60))
        let oversized = EquationAttachment(latex: #"\frac{x}{y}"#, fontSize: 16,
                                            previewPDF: preview.dataWithPDF(inside: preview.bounds),
                                            previewMetrics: .init(width: 100, height: 60, baseline: 40))
        let narrow = NSTextContainer(size: NSSize(width: 24, height: 100))
        let fitted = oversized.attachmentBounds(for: narrow, proposedLineFragment: CGRect(origin: .zero, size: narrow.size),
                                                 glyphPosition: .zero, characterIndex: 0)
        XCTAssertLessThanOrEqual(fitted.width, 24)
        XCTAssertEqual(fitted.height, 14.4, accuracy: 0.01)
        XCTAssertTrue(fitted.width.isFinite && fitted.height.isFinite)
    }

    func testSourceFallbackAlignsToTextFontBaseline() {
        let font = NSFont.systemFont(ofSize: 16)
        let attachment = EquationAttachment(latex: "x", fontSize: 16)

        XCTAssertEqual(attachment.bounds.minY, font.descender, accuracy: 0.01)
    }

    // MARK: - NotePackage tests

    func testNotePackageFileWrapperCreation() throws {
        let doc = NoteDocument(strokes: [], textBlocks: [], viewport: nil)
        let wrapper = try NotePackage.fileWrapper(for: doc)

        XCTAssertEqual(wrapper.filename, nil) // directory wrapper
        XCTAssertNotNil(wrapper.fileWrappers)
        XCTAssertTrue(wrapper.fileWrappers?[NotePackage.documentFileName] != nil)
    }

    func testNotePackageDocumentExtraction() throws {
        let stroke = Stroke(
            id: UUID(),
            points: [StrokePoint(x: 5, y: 5, t: 0)],
            color: .black,
            width: 2
        )
        let original = NoteDocument(strokes: [stroke], textBlocks: [], viewport: nil)
        let wrapper = try NotePackage.fileWrapper(for: original)

        let extracted = try NotePackage.document(from: wrapper)
        XCTAssertEqual(extracted.version, original.version)
        XCTAssertEqual(extracted.strokes.count, 1)
        XCTAssertEqual(extracted.strokes[0].id, stroke.id)
    }

    func testNotePackageWriteAndRead() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stroke = Stroke(
            id: UUID(),
            points: [
                StrokePoint(x: 0, y: 0, t: 0),
                StrokePoint(x: 20, y: 30, t: 0.5)
            ],
            color: .orange,
            width: 4.5
        )
        let viewport = Viewport(center: CGPoint(x: 50, y: 100), magnification: 2)
        let original = NoteDocument(strokes: [stroke], textBlocks: [], viewport: viewport)

        let packageURL = tempDir.appendingPathComponent("TestNote.\(NotePackage.fileExtension)")
        try NotePackage.write(original, to: packageURL)

        // Verify directory structure
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
        let documentURL = packageURL.appendingPathComponent(NotePackage.documentFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentURL.path))

        // Read back and verify
        let read = try NotePackage.read(from: packageURL)
        XCTAssertEqual(read.version, NoteDocument.currentVersion)
        XCTAssertEqual(read.strokes.count, 1)
        XCTAssertEqual(read.strokes[0].id, stroke.id)
        XCTAssertEqual(read.strokes[0].width, 4.5)
        XCTAssertEqual(read.viewport, viewport)
    }

    func testNotePackageOverwrite() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let packageURL = tempDir.appendingPathComponent("Note.\(NotePackage.fileExtension)")

        let stroke1 = Stroke(id: UUID(), points: [StrokePoint(x: 0, y: 0, t: 0)], color: .red, width: 1)
        let doc1 = NoteDocument(strokes: [stroke1], textBlocks: [], viewport: nil)
        try NotePackage.write(doc1, to: packageURL)

        let stroke2 = Stroke(id: UUID(), points: [StrokePoint(x: 10, y: 10, t: 0)], color: .blue, width: 2)
        let doc2 = NoteDocument(strokes: [stroke2], textBlocks: [], viewport: nil)
        try NotePackage.write(doc2, to: packageURL)

        let read = try NotePackage.read(from: packageURL)
        XCTAssertEqual(read.strokes.count, 1)
        XCTAssertEqual(read.strokes[0].id, stroke2.id)
        XCTAssertEqual(read.strokes[0].color, .blue)
    }

    func testNotePackageMissingDocument() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let emptyPackageURL = tempDir.appendingPathComponent("Empty.\(NotePackage.fileExtension)")
        try FileManager.default.createDirectory(at: emptyPackageURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try NotePackage.read(from: emptyPackageURL)) { error in
            XCTAssertEqual(error as? NotePackageError, .missingDocument)
        }
    }

    func testNotePackageUnsupportedVersion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let packageURL = tempDir.appendingPathComponent("BadVersion.\(NotePackage.fileExtension)")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let documentURL = packageURL.appendingPathComponent(NotePackage.documentFileName)
        let jsonString = """
        {"version":\(NoteDocument.currentVersion + 1),"strokes":[],"textBlocks":[]}
        """
        try jsonString.data(using: .utf8)!.write(to: documentURL)

        XCTAssertThrowsError(try NotePackage.read(from: packageURL)) { error in
            if let pkgError = error as? NotePackageError {
                if case .unsupportedVersion(let v) = pkgError {
                    XCTAssertEqual(v, NoteDocument.currentVersion + 1)
                } else {
                    XCTFail("Expected unsupportedVersion error")
                }
            } else {
                XCTFail("Expected NotePackageError")
            }
        }
    }

    // MARK: - NoteLibrary tests

    func testNoteLibraryInitCreatesRoot() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.path))
        XCTAssertEqual(library.items.count, 0)
    }

    func testNoteLibraryCreateNote() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let noteURL = try library.createNote(named: "TestNote")

        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path))
        XCTAssertTrue(noteURL.lastPathComponent.hasSuffix(".\(NotePackage.fileExtension)"))
        XCTAssertEqual(library.items.count, 1)
    }

    func testNoteLibraryCreateNoteUniqueNames() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)

        let url1 = try library.createNote(named: "Untitled")
        XCTAssertTrue(url1.lastPathComponent.hasPrefix("Untitled"))

        let url2 = try library.createNote(named: "Untitled")
        XCTAssertNotEqual(url1, url2)
        XCTAssertTrue(url2.lastPathComponent.contains("2"))

        let url3 = try library.createNote(named: "Untitled")
        XCTAssertTrue(url3.lastPathComponent.contains("3"))
    }

    func testNoteLibraryCreateFolder() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let folderURL = try library.createFolder(named: "MyFolder")

        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(library.items[0].kind, .folder)
    }

    func testNoteLibraryCreateNoteInFolder() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let folderURL = try library.createFolder(named: "Folder")
        let noteURL = try library.createNote(in: folderURL, named: "Note")

        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path))
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(library.items[0].children?.count, 1)
    }

    func testNoteLibraryItemsOrderingFoldersFirst() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        try library.createNote(named: "Note A")
        try library.createFolder(named: "Folder B")
        try library.createNote(named: "Note C")

        XCTAssertEqual(library.items.count, 3)
        XCTAssertEqual(library.items[0].kind, .folder)
        XCTAssertEqual(library.items[1].kind, .note)
        XCTAssertEqual(library.items[2].kind, .note)
    }

    func testNoteLibraryItemsOrderingLocalizedStandard() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        try library.createNote(named: "Note 10")
        try library.createNote(named: "Note 2")
        try library.createNote(named: "Note 1")

        XCTAssertEqual(library.items.count, 3)
        XCTAssertEqual(library.items[0].name, "Note 1")
        XCTAssertEqual(library.items[1].name, "Note 2")
        XCTAssertEqual(library.items[2].name, "Note 10")
    }

    func testNoteLibraryIgnoresHiddenAndNonNoteFiles() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Create a note the normal way
        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        try library.createNote(named: "GoodNote")

        // Create hidden files and other files directly in the root
        try Data().write(to: tempRoot.appendingPathComponent(".hidden"))
        try Data().write(to: tempRoot.appendingPathComponent("other.txt"))

        library.reload()

        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(library.items[0].name, "GoodNote")
    }

    func testNoteLibraryRenameNote() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let originalURL = try library.createNote(named: "Original")

        let newURL = try library.rename(originalURL, to: "Renamed")

        XCTAssertNotEqual(originalURL, newURL)
        XCTAssertTrue(newURL.lastPathComponent.hasPrefix("Renamed"))
        XCTAssertTrue(newURL.lastPathComponent.hasSuffix(".\(NotePackage.fileExtension)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
    }

    func testNoteLibraryRenameToSameName() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let url = try library.createNote(named: "SameName")
        let result = try library.rename(url, to: "SameName")

        XCTAssertEqual(url, result)
    }

    func testNoteLibraryRenameToTakenNameThrows() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        _ = try library.createNote(named: "Note1")
        let url2 = try library.createNote(named: "Note2")

        XCTAssertThrowsError(try library.rename(url2, to: "Note1")) { error in
            XCTAssertEqual(error as? NoteLibraryError, .nameTaken)
        }
    }

    func testNoteLibraryInvalidNames() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)

        XCTAssertThrowsError(try library.createNote(named: "")) { error in
            XCTAssertEqual(error as? NoteLibraryError, .invalidName)
        }

        XCTAssertThrowsError(try library.createNote(named: "   ")) { error in
            XCTAssertEqual(error as? NoteLibraryError, .invalidName)
        }

        XCTAssertThrowsError(try library.createNote(named: "a/b")) { error in
            XCTAssertEqual(error as? NoteLibraryError, .invalidName)
        }

        XCTAssertThrowsError(try library.createNote(named: ".hidden")) { error in
            XCTAssertEqual(error as? NoteLibraryError, .invalidName)
        }
    }

    func testNoteLibraryMove() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let folderURL = try library.createFolder(named: "Folder")
        let noteURL = try library.createNote(named: "Note")

        let movedURL = try library.move(noteURL, into: folderURL)

        XCTAssertNotEqual(noteURL, movedURL)
        XCTAssertTrue(movedURL.path.contains(folderURL.lastPathComponent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedURL.path))
    }

    func testNoteLibraryMoveToRoot() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let folderURL = try library.createFolder(named: "Folder")
        let noteURL = try library.createNote(in: folderURL, named: "Note")

        let movedURL = try library.move(noteURL, into: nil)

        XCTAssertNotEqual(noteURL, movedURL)
        XCTAssertFalse(movedURL.path.contains(folderURL.lastPathComponent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedURL.path))
    }

    func testNoteLibraryMoveWithNameCollisionGetsUniqued() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let folderURL = try library.createFolder(named: "Folder")
        try library.createNote(in: folderURL, named: "Note")
        let note2URL = try library.createNote(named: "Note")

        let movedURL = try library.move(note2URL, into: folderURL)

        XCTAssertTrue(movedURL.path.contains(folderURL.lastPathComponent))
        XCTAssertTrue(movedURL.lastPathComponent.contains("2"))
    }

    func testNoteLibraryMoveIntoItselfThrows() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let folderURL = try library.createFolder(named: "Folder")

        XCTAssertThrowsError(try library.move(folderURL, into: folderURL)) { error in
            XCTAssertEqual(error as? NoteLibraryError, .invalidMove)
        }
    }

    func testNoteLibraryMoveIntoDescendantThrows() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let parentURL = try library.createFolder(named: "Parent")
        let childURL = try library.createFolder(in: parentURL, named: "Child")

        XCTAssertThrowsError(try library.move(parentURL, into: childURL)) { error in
            XCTAssertEqual(error as? NoteLibraryError, .invalidMove)
        }
    }

    func testNoteLibraryMoveToTrash() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let noteURL = try library.createNote(named: "ToTrash")

        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path))
        try library.moveToTrash(noteURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path))

        library.reload()
        XCTAssertEqual(library.items.count, 0)
    }

    func testNoteLibrarySearch() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        try library.createNote(named: "Café Notes")
        try library.createNote(named: "Shopping")
        try library.createNote(named: "Cafe Ideas")

        let results = library.search("cafe")
        XCTAssertEqual(results.count, 2)
    }

    func testNoteLibrarySearchEmpty() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        try library.createNote(named: "Something")

        let results = library.search("")
        XCTAssertEqual(results.count, 0)
    }

    func testNoteLibrarySearchFindNested() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let folderURL = try library.createFolder(named: "Folder")
        try library.createNote(in: folderURL, named: "NestedNote")

        let results = library.search("nested")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "NestedNote")
    }

    func testNoteLibraryNoteOpened() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let url1 = try library.createNote(named: "Note1")
        let url2 = try library.createNote(named: "Note2")

        library.noteOpened(url1)
        XCTAssertEqual(library.recents.first, url1)

        library.noteOpened(url2)
        XCTAssertEqual(library.recents.first, url2)
        XCTAssertEqual(library.recents[1], url1)
    }

    func testNoteLibraryRecentsDeduplicated() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let url = try library.createNote(named: "Note")

        library.noteOpened(url)
        library.noteOpened(url)

        XCTAssertEqual(library.recents.count, 1)
        XCTAssertEqual(library.recents[0], url)
    }

    func testNoteLibraryRecentsMaximumCapped() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)

        var urls: [URL] = []
        for i in 0..<(NoteLibrary.maxRecents + 5) {
            let url = try library.createNote(named: "Note\(i)")
            urls.append(url)
            library.noteOpened(url)
        }

        XCTAssertEqual(library.recents.count, NoteLibrary.maxRecents)
    }

    func testNoteLibraryLastOpenedNote() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let url = try library.createNote(named: "Note")

        XCTAssertNil(library.lastOpenedNote)

        library.noteOpened(url)
        XCTAssertEqual(library.lastOpenedNote, url)
    }

    func testNoteLibraryTrashRemovesFromRecents() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let url1 = try library.createNote(named: "Note1")
        let url2 = try library.createNote(named: "Note2")

        library.noteOpened(url1)
        library.noteOpened(url2)
        XCTAssertEqual(library.recents.count, 2)

        try library.moveToTrash(url2)
        XCTAssertEqual(library.recents.count, 1)
        XCTAssertEqual(library.recents[0], url1)
    }

    func testNoteLibraryRecentsFollowRenames() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let url = try library.createNote(named: "Original")
        library.noteOpened(url)

        let renamedURL = try library.rename(url, to: "Renamed")
        XCTAssertEqual(library.recents[0], renamedURL)
        XCTAssertEqual(library.lastOpenedNote, renamedURL)
    }

    func testNoteLibraryRecentsFollowMoves() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = try NoteLibrary(root: tempRoot, defaults: defaults)
        let folderURL = try library.createFolder(named: "Folder")
        let noteURL = try library.createNote(named: "Note")
        library.noteOpened(noteURL)

        let movedURL = try library.move(noteURL, into: folderURL)
        XCTAssertEqual(library.recents[0], movedURL)
        XCTAssertEqual(library.lastOpenedNote, movedURL)
    }

    func testNoteLibraryMultipleInstancesShareRecents() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let lib1 = try NoteLibrary(root: tempRoot, defaults: defaults)
        let url = try lib1.createNote(named: "Note")
        lib1.noteOpened(url)

        let lib2 = try NoteLibrary(root: tempRoot, defaults: defaults)
        XCTAssertEqual(lib2.recents.count, 1)
        XCTAssert(lib2.recents[0].path.contains("Note"))
    }

    // MARK: - NoteAutosaver tests

    func testAutosaverSynchronizesLiveContentsBeforeFlush() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Live.scratch")
        let body = TextBlock(origin: .zero)
        let model = CanvasModel(textBlocks: [body], layout: .document)
        let saver = NoteAutosaver(model: model, url: url)
        saver.beforeSnapshot = {
            var updated = body
            updated.content = TextBlock.content(from: NSAttributedString(string: "Latest typing"))
            model.updateTextBlock(updated, actionName: nil)
        }
        saver.markDirty()
        XCTAssertTrue(saver.flush())
        XCTAssertEqual(try NotePackage.read(from: url).textBlocks.first?.attributedString.string, "Latest typing")
    }

    func testNoteAutosaverMarkDirtySchedulesSave() throws {
        let model = CanvasModel()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("Test.\(NotePackage.fileExtension)")
        let autosaver = NoteAutosaver(model: model, url: url, delay: 0.05)

        XCTAssertFalse(autosaver.isDirty)
        autosaver.markDirty()
        XCTAssertTrue(autosaver.isDirty)

        let expectation = XCTestExpectation(description: "Save completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertFalse(autosaver.isDirty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testNoteAutosaverMultipleMarkDirtiesCoalesce() throws {
        let model = CanvasModel()
        let stroke = Stroke(
            id: UUID(),
            points: [StrokePoint(x: 0, y: 0, t: 0)],
            color: .blue,
            width: 2
        )
        model.add(stroke)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("Test.\(NotePackage.fileExtension)")
        let autosaver = NoteAutosaver(model: model, url: url, delay: 0.05)

        autosaver.markDirty()
        autosaver.markDirty()
        autosaver.markDirty()

        let expectation = XCTestExpectation(description: "Saves coalesced")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        let doc = try NotePackage.read(from: url)
        XCTAssertEqual(doc.strokes.count, 1)
    }

    func testNoteAutosaverFlush() throws {
        let model = CanvasModel()
        let stroke = Stroke(
            id: UUID(),
            points: [StrokePoint(x: 1, y: 2, t: 0)],
            color: .red,
            width: 1.5
        )
        model.add(stroke)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("Test.\(NotePackage.fileExtension)")
        let autosaver = NoteAutosaver(model: model, url: url, delay: 0.05)

        autosaver.markDirty()
        let flushed = autosaver.flush()

        XCTAssertTrue(flushed)
        XCTAssertFalse(autosaver.isDirty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let doc = try NotePackage.read(from: url)
        XCTAssertEqual(doc.strokes.count, 1)
    }

    func testNoteAutosaverFlushNoChangeReturnsFalse() throws {
        let model = CanvasModel()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("Test.\(NotePackage.fileExtension)")
        let autosaver = NoteAutosaver(model: model, url: url)

        let flushed = autosaver.flush()
        XCTAssertFalse(flushed)
    }

    func testNoteAutosaverViewportChangeMarksDirty() throws {
        let model = CanvasModel()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("Test.\(NotePackage.fileExtension)")
        let savedViewport = Viewport(center: CGPoint(x: 0, y: 0), magnification: 1)
        let autosaver = NoteAutosaver(model: model, url: url, lastSavedViewport: savedViewport)

        autosaver.viewportProvider = {
            Viewport(center: CGPoint(x: 10, y: 10), magnification: 2)
        }

        let flushed = autosaver.flush()
        XCTAssertTrue(flushed)
    }

    func testNoteAutosaverUndoMarksDirty() throws {
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false
        let stroke = Stroke(
            id: UUID(),
            points: [StrokePoint(x: 0, y: 0, t: 0)],
            color: .black,
            width: 2
        )

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("Test.\(NotePackage.fileExtension)")
        let autosaver = NoteAutosaver(model: model, url: url, delay: 0.05)

        model.undoManager.beginUndoGrouping()
        model.add(stroke)
        model.undoManager.endUndoGrouping()

        XCTAssertTrue(autosaver.isDirty)

        let expectation = XCTestExpectation(description: "Saved after dirty")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertFalse(autosaver.isDirty)

        model.undoManager.undo()
        XCTAssertTrue(autosaver.isDirty)
    }

    func testNoteAutosaverUrlChange() throws {
        let model = CanvasModel()
        let stroke = Stroke(
            id: UUID(),
            points: [StrokePoint(x: 0, y: 0, t: 0)],
            color: .green,
            width: 2
        )
        model.add(stroke)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url1 = tempDir.appendingPathComponent("Test1.\(NotePackage.fileExtension)")
        let url2 = tempDir.appendingPathComponent("Test2.\(NotePackage.fileExtension)")

        var autosaver = NoteAutosaver(model: model, url: url1, delay: 0.05)
        defer { autosaver.close() }
        autosaver.markDirty()

        let expectation = XCTestExpectation(description: "First save completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url1.path))

        autosaver.url = url2
        autosaver.markDirty()

        let expectation2 = XCTestExpectation(description: "Second save completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation2.fulfill()
        }
        wait(for: [expectation2], timeout: 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url2.path))
    }

    // MARK: - SettingsPersistence tests

    func testSettingsPersistenceLoadsDefaults() throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = CanvasSettings()
        _ = SettingsPersistence(settings: settings, defaults: defaults)

        XCTAssertEqual(settings.tool, .pen)
        XCTAssertEqual(settings.color, .black)
        XCTAssertEqual(settings.inputMode, .pen)
        XCTAssertEqual(settings.defaultLayout, .document)
    }

    func testSettingsPersistenceSavesToDefaults() throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = CanvasSettings()
        let persistence = SettingsPersistence(settings: settings, defaults: defaults)

        settings.tool = .eraser
        settings.color = .red
        settings.width = 5.5
        settings.eraserRadius = 12
        settings.inputMode = .pen
        settings.penKey = .option
        settings.activation = .toggle
        settings.defaultLayout = .canvas

        // Give persistence time to save (it might be debounced)
        let expectation = XCTestExpectation(description: "Settings saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        let newSettings = CanvasSettings()
        let _ = SettingsPersistence(settings: newSettings, defaults: defaults)

        XCTAssertEqual(newSettings.tool, .eraser, "Tool should be persisted")
        XCTAssertEqual(newSettings.color, .red, "Color should be persisted")
        XCTAssertEqual(newSettings.width, 5.5, "Width should be persisted")
        XCTAssertEqual(newSettings.eraserRadius, 12, "EraserRadius should be persisted")
        XCTAssertEqual(newSettings.inputMode, .pen, "InputMode should be persisted")
        XCTAssertEqual(newSettings.penKey, .option, "PenKey should be persisted")
        XCTAssertEqual(newSettings.activation, .toggle, "Activation should be persisted")
        XCTAssertEqual(defaults.string(forKey: "settings.defaultLayout"), "canvas")
        XCTAssertEqual(newSettings.defaultLayout, .canvas, "Default note layout should be persisted")
    }

    func testSettingsPersistenceTabletLoadsAsPen() throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("tablet", forKey: "settings.inputMode")

        let settings = CanvasSettings()
        let _ = SettingsPersistence(settings: settings, defaults: defaults)

        XCTAssertEqual(settings.inputMode, .pen)
    }

    func testSettingsPersistenceWriteLoadsAsPen() throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("write", forKey: "settings.inputMode")

        let settings = CanvasSettings()
        let _ = SettingsPersistence(settings: settings, defaults: defaults)

        XCTAssertEqual(settings.inputMode, .pen)
    }

    func testWritingLineHeightFollowsFontSize() throws {
        let settings = CanvasSettings()
        XCTAssertEqual(settings.writingLineHeight, settings.defaultFontSize)
        settings.defaultFontSize = 44
        XCTAssertEqual(settings.writingLineHeight, 44, "The handwriting cell must track the font size")
    }

    func testDefaultFontSizePersistsAndRejectsInvalidStoredValues() throws {
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = CanvasSettings()
        let persistence = SettingsPersistence(settings: settings, defaults: defaults)
        XCTAssertEqual(settings.defaultFontSize, 15)
        settings.defaultFontSize = 24.5
        XCTAssertEqual(defaults.double(forKey: "settings.defaultFontSize"), 24.5)
        let restored = CanvasSettings()
        _ = SettingsPersistence(settings: restored, defaults: defaults)
        XCTAssertEqual(restored.defaultFontSize, 24.5)
        settings.defaultFontSize = 200
        XCTAssertEqual(settings.defaultFontSize, 72)
        XCTAssertEqual(defaults.double(forKey: "settings.defaultFontSize"), 72)
        settings.defaultFontSize = -1
        XCTAssertEqual(settings.defaultFontSize, 8)
        settings.defaultFontSize = .nan
        XCTAssertEqual(settings.defaultFontSize, 15)
        XCTAssertEqual(defaults.double(forKey: "settings.defaultFontSize"), 15)
        withExtendedLifetime(persistence) {}
        for invalid: Double in [0, 200, .infinity] {
            defaults.set(invalid, forKey: "settings.defaultFontSize")
            let fresh = CanvasSettings()
            _ = SettingsPersistence(settings: fresh, defaults: defaults)
            XCTAssertEqual(fresh.defaultFontSize, 15, "Invalid saved sizes keep the default")
        }
    }

    func testSettingsPersistenceGarbageValueKeepsDefault() throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("garbage", forKey: "settings.tool")

        let settings = CanvasSettings()
        let _ = SettingsPersistence(settings: settings, defaults: defaults)

        XCTAssertEqual(settings.tool, .pen)
    }

    // MARK: Discard (lead)

    func testDiscardNeverWritesAfterTrash() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let url = tempDir.appendingPathComponent("Gone.\(NotePackage.fileExtension)")
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let saver = NoteAutosaver(model: model, url: url, delay: 0.05)
        XCTAssertTrue(saver.flush() || !saver.isDirty)
        try NotePackage.write(NoteDocument(), to: url)
        try FileManager.default.removeItem(at: url) // simulates trashing
        saver.discard()
        um.beginUndoGrouping()
        model.add(Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 2))
        um.endUndoGrouping() // e.g. a text draft committed during teardown
        XCTAssertFalse(saver.flush())
        saver.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
