import Foundation
import CoreGraphics
import ImageIO
import SQLite3
import UniformTypeIdentifiers

enum SelfTestRunner {
    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run() async -> Int32 {
        var checks: [(String, () async throws -> Void)] = [
            ("Dateitypen", checkFileTypes),
            ("Rekursion und RAW-Paarung", checkRecursiveGrouping),
            ("Warnschwelle für große Fotoordner", checkLargeFolderWarningThreshold),
            ("Versteckte Ordner und Pakete", checkSkippedDirectories),
            ("Stabile IDs", checkStableIDs),
            ("Sortierungen", checkSorting),
            ("ESC-Navigation", checkEscapeNavigation),
            ("Mehrfachauswahl und Batch-Exportziele", checkMultiSelectionAndBatchDestinations),
            ("Blocksatz-Layout", checkJustifiedLayout),
            ("Letzter geöffneter Ordner", checkLastSelectedFolder),
            ("Kleine Standardbilder", checkSmallStandardRendering),
            ("Bildmetadaten", checkImageMetadata),
            ("SQLite-Fotoindex", checkPhotoCatalog),
            ("Drehlogik und Drehkatalog", checkPhotoRotation),
            ("KI-Schlagwortindex", checkPhotoAnalysisCatalog),
            ("Katalogmigration", checkLegacyCatalogMigration),
            ("XMP-Sidecars", checkXMPSidecars),
            ("XMP-Exportabfrage", checkXMPExportSuggestion),
            ("Softwareupdates", checkSoftwareUpdates),
            ("LM-Studio-Konfiguration", checkLMStudioConfiguration),
            ("Metadaten-Cache", checkMetadataReuse),
            ("Einheitlicher 1024er-Thumbnail-Cache", checkThumbnailBuckets),
            ("JPEG-Export", checkJPEGExport),
            ("Scan-Abbruch", checkCancellation),
            ("10.000 Dateieinträge", checkTenThousandFiles)
        ]
        if ProcessInfo.processInfo.environment["RAW_VIEWER_LIVE_UPDATE_TEST"] == "1" {
            checks.append(("Öffentliches Softwareupdate", checkLiveSoftwareUpdate))
        }
        print("RAW Viewer Self-Tests")
        for (name, check) in checks {
            do {
                try await check()
                print("✓ \(name)")
            } catch {
                print("✗ \(name): \(error.localizedDescription)")
                return 1
            }
        }
        print("Alle \(checks.count) Prüfungen bestanden.")
        return 0
    }

    private static func checkFileTypes() async throws {
        try require(PhotoFileKind.classify(URL(fileURLWithPath: "/tmp/photo.CR3")) == .raw, "CR3 nicht als RAW erkannt")
        try require(PhotoFileKind.classify(URL(fileURLWithPath: "/tmp/photo.NEF")) == .raw, "NEF nicht als RAW erkannt")
        try require(PhotoFileKind.classify(URL(fileURLWithPath: "/tmp/photo.ARW")) == .raw, "ARW nicht als RAW erkannt")
        try require(PhotoFileKind.classify(URL(fileURLWithPath: "/tmp/photo.RAF")) == .raw, "RAF nicht als RAW erkannt")
        try require(PhotoFileKind.classify(URL(fileURLWithPath: "/tmp/photo.JPG")) == .jpeg, "JPEG nicht erkannt")
        try require(PhotoFileKind.classify(URL(fileURLWithPath: "/tmp/photo.HEIC")) == .heic, "HEIC nicht erkannt")
        try require(PhotoFileKind.classify(URL(fileURLWithPath: "/tmp/photo.PNG")) == .png, "PNG nicht erkannt")
        try require(PhotoFileKind.classify(URL(fileURLWithPath: "/tmp/photo.TIFF")) == .tiff, "TIFF nicht erkannt")
        try require(PhotoFileKind.classify(URL(fileURLWithPath: "/tmp/readme.txt")) == nil, "Textdatei fälschlich erkannt")
    }

    private static func checkRecursiveGrouping() async throws {
        try await withTemporaryDirectory { root in
            let session = root.appendingPathComponent("Session", isDirectory: true)
            let other = root.appendingPathComponent("Other", isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            touch(session.appendingPathComponent("IMG_0001.CR3"))
            touch(session.appendingPathComponent("img_0001.jpg"))
            touch(session.appendingPathComponent("IMG_0002.PNG"))
            touch(other.appendingPathComponent("IMG_0001.JPG"))

            let photos = try await PhotoScanner().scan(folderURL: root)
            try require(photos.count == 3, "Erwartet 3 Fotos, erhalten: \(photos.count)")
            guard let pair = photos.first(where: { $0.rawURL?.lastPathComponent == "IMG_0001.CR3" }) else {
                throw CheckFailure(message: "RAW/JPEG-Paar fehlt")
            }
            try require(pair.companionURLs.map(\.lastPathComponent) == ["img_0001.jpg"], "JPEG wurde nicht gebündelt")
            try require(pair.previewURL.lastPathComponent == "img_0001.jpg", "JPEG ist nicht die bevorzugte Vorschau")
            try require(photos.contains(where: { $0.primaryURL.lastPathComponent == "IMG_0002.PNG" }), "PNG fehlt")
        }
    }

    private static func checkSkippedDirectories() async throws {
        try await withTemporaryDirectory { root in
            let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
            let package = root.appendingPathComponent("Preview.app", isDirectory: true)
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            touch(hidden.appendingPathComponent("hidden.jpg"))
            touch(package.appendingPathComponent("packaged.jpg"))
            touch(root.appendingPathComponent("visible.jpg"))
            let photos = try await PhotoScanner().scan(folderURL: root)
            try require(photos.map(\.filename) == ["visible.jpg"], "Versteckte oder paketinterne Datei wurde eingelesen")
        }
    }

    private static func checkLargeFolderWarningThreshold() async throws {
        try await withTemporaryDirectory { root in
            let nested = root.appendingPathComponent("Unterordner", isDirectory: true)
            let hidden = root.appendingPathComponent(".versteckt", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)

            touch(root.appendingPathComponent("paar.CR3"))
            touch(root.appendingPathComponent("paar.jpg"))
            touch(nested.appendingPathComponent("einzeln.jpg"))
            touch(nested.appendingPathComponent("einzeln.heic"))
            touch(nested.appendingPathComponent("grafik.png"))
            touch(hidden.appendingPathComponent("ignoriert.jpg"))

            let checker = PhotoFolderSizeChecker()
            let exact = try await checker.check(folderURL: root, limit: 10)
            try require(exact.photoCount == 4 && !exact.exceedsLimit, "Fotoanzahl berücksichtigt Gruppierung oder Unterordner nicht korrekt")

            let warning = try await checker.check(folderURL: root, limit: 3)
            try require(warning.exceedsLimit, "Großer Fotoordner überschreitet die Warnschwelle nicht")
        }
    }

    private static func checkStableIDs() async throws {
        try await withTemporaryDirectory { root in
            touch(root.appendingPathComponent("stable.dng"))
            touch(root.appendingPathComponent("stable.jpeg"))
            let first = try await PhotoScanner().scan(folderURL: root)
            let second = try await PhotoScanner().scan(folderURL: root)
            try require(first.count == 1, "RAW/JPEG wurde nicht zu einem Eintrag gebündelt")
            try require(first.map(\.id) == second.map(\.id), "IDs ändern sich zwischen Scans")
        }
    }

    private static func checkSorting() async throws {
        let older = asset(name: "B.jpg", date: Date(timeIntervalSince1970: 100))
        let newerA = asset(name: "A.jpg", date: Date(timeIntervalSince1970: 200))
        let newerC = asset(name: "C.jpg", date: Date(timeIntervalSince1970: 200))
        let input = [older, newerC, newerA]
        try require(PhotoSortOrder.newestFirst.sort(input).map(\.filename) == ["A.jpg", "C.jpg", "B.jpg"], "Neueste-Sortierung falsch")
        try require(PhotoSortOrder.oldestFirst.sort(input).map(\.filename) == ["B.jpg", "A.jpg", "C.jpg"], "Älteste-Sortierung falsch")
        try require(PhotoSortOrder.filenameAscending.sort(input).map(\.filename) == ["A.jpg", "B.jpg", "C.jpg"], "A–Z-Sortierung falsch")
        try require(PhotoSortOrder.filenameDescending.sort(input).map(\.filename) == ["C.jpg", "B.jpg", "A.jpg"], "Z–A-Sortierung falsch")
    }

    private static func checkEscapeNavigation() async throws {
        try require(
            LibraryViewMode.photo.escapeKeyAction == .closePhoto,
            "ESC schließt die Einzelbildansicht nicht"
        )
        try require(
            LibraryViewMode.grid.escapeKeyAction == .clearSelection,
            "ESC hebt die Galerieauswahl nicht auf"
        )
    }

    private static func checkXMPExportSuggestion() async throws {
        let single = XMPExportSuggestion(photoIDs: ["photo-1"])
        try require(single.photoCount == 1, "Einzelfoto-Abfrage zählt falsch")
        try require(single.message.contains("RAW-Foto"), "Einzelfoto-Abfrage ist nicht verständlich")

        let multiple = XMPExportSuggestion(photoIDs: ["photo-1", "photo-2"])
        try require(multiple.photoCount == 2, "Mehrfachfoto-Abfrage zählt falsch")
        try require(multiple.message.contains("2 eben verschlagworteten RAW-Fotos"), "Mehrfachfoto-Abfrage ist nicht verständlich")
    }

    private static func checkSoftwareUpdates() async throws {
        guard let current = SemanticVersion(string: "0.6.2"),
              let older = SemanticVersion(string: "v0.6.1"),
              let newer = SemanticVersion(string: "1.0.0") else {
            throw CheckFailure(message: "Versionsnummern können nicht gelesen werden")
        }
        try require(older < current && current < newer, "Versionsvergleich ist falsch")

        let releaseJSON = """
        {
          "tag_name": "v0.6.3",
          "html_url": "https://github.com/r3d42-git/R3Ds_RAW-Viewer/releases/tag/v0.6.3",
          "assets": [
            {
              "name": "RAW-Viewer-0.6.3-macOS-arm64.zip",
              "browser_download_url": "https://example.invalid/RAW-Viewer-0.6.3-macOS-arm64.zip",
              "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
              "size": 1024
            }
          ]
        }
        """.data(using: .utf8)!
        let update = try SoftwareUpdateService.update(fromReleaseData: releaseJSON, currentVersion: current)
        try require(update?.version.description == "0.6.3", "Neues GitHub-Release wird nicht erkannt")
        try require(update?.expectedSHA256.count == 64, "SHA-256-Digest wird nicht übernommen")
        let olderUpdate = try SoftwareUpdateService.update(fromReleaseData: releaseJSON, currentVersion: newer)
        try require(
            olderUpdate == nil,
            "Kein älteres Update darf angeboten werden"
        )
    }

    private static func checkLiveSoftwareUpdate() async throws {
        guard let previousVersion = SemanticVersion(string: "0.0.0") else {
            throw CheckFailure(message: "Testversion kann nicht gelesen werden")
        }
        let service = SoftwareUpdateService()
        guard let update = try await service.fetchLatestUpdate(currentVersion: previousVersion) else {
            throw CheckFailure(message: "Das öffentliche Release wurde nicht als Update erkannt")
        }
        let preparedUpdate = try await service.downloadAndPrepare(update)
        defer { try? FileManager.default.removeItem(at: preparedUpdate.workingDirectory) }
        try require(
            FileManager.default.fileExists(atPath: preparedUpdate.appURL.appendingPathComponent("Contents/MacOS/RAWViewer").path),
            "Das geprüfte öffentliche Update enthält keine ausführbare App"
        )
    }

    private static func checkMultiSelectionAndBatchDestinations() async throws {
        let orderedIDs = ["a", "b", "c", "d"]
        var selection = PhotoSelection()
        selection.select("b", orderedIDs: orderedIDs)
        selection.select("d", orderedIDs: orderedIDs, modifiers: [.range])
        try require(selection.ids == Set(["b", "c", "d"]), "Bereichsauswahl ist falsch")
        try require(selection.primaryID == "d", "Primärfoto der Bereichsauswahl ist falsch")

        selection.select("c", orderedIDs: orderedIDs, modifiers: [.toggle])
        try require(selection.ids == Set(["b", "d"]), "⌘-Klick entfernt kein ausgewähltes Foto")
        selection.select("d", orderedIDs: orderedIDs, modifiers: [.toggle, .range])
        try require(selection.ids == Set(["b", "c", "d"]), "⌘⇧-Klick ergänzt den Bereich nicht")

        selection.selectAll(orderedIDs)
        try require(selection.count == 4, "Alle sichtbaren Fotos wurden nicht ausgewählt")
        selection.prune(to: ["a", "c"])
        try require(selection.ids == Set(["a", "c"]), "Gelöschte Fotos blieben in der Auswahl")
        selection.clear()
        try require(selection.isEmpty && selection.primaryID == nil, "Auswahl wurde nicht vollständig aufgehoben")

        try await withTemporaryDirectory { root in
            let source = asset(name: "foto.jpg", date: Date())
            touch(root.appendingPathComponent("foto.jpg"))
            var reservedPaths: Set<String> = []
            let first = PhotoExportService.availableDestinationURL(
                for: source,
                format: .jpeg,
                in: root,
                reservedPaths: &reservedPaths
            )
            let second = PhotoExportService.availableDestinationURL(
                for: source,
                format: .jpeg,
                in: root,
                reservedPaths: &reservedPaths
            )
            try require(first.lastPathComponent == "foto (2).jpg", "Vorhandenes Batch-Ziel würde überschrieben")
            try require(second.lastPathComponent == "foto (3).jpg", "Doppelte Batch-Dateinamen sind nicht eindeutig")
        }
    }

    private static func checkJustifiedLayout() async throws {
        try require(
            ImageMetadataReader.displayAspectRatio(pixelWidth: 6_000, pixelHeight: 4_000, orientation: 1) == 1.5,
            "Querformat-Seitenverhältnis ist falsch"
        )
        try require(
            ImageMetadataReader.displayAspectRatio(pixelWidth: 6_000, pixelHeight: 4_000, orientation: 6) == 2.0 / 3.0,
            "EXIF-gedrehtes Hochformat wird nicht berücksichtigt"
        )
        let photos = (0..<4).map { index in
            asset(name: "layout-\(index).jpg", date: Date(timeIntervalSince1970: Double(index)))
        }
        let ratios = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, 4.0 / 3.0) })
        let rows = JustifiedPhotoLayout.rows(
            photos: photos,
            aspectRatios: ratios,
            availableWidth: 600,
            targetImageHeight: 150
        )
        try require(rows.count == 2, "Blocksatz bildet nicht die erwarteten Zeilen")
        let firstWidth = rows[0].items.reduce(0) { $0 + $1.width }
            + Double(rows[0].items.count - 1) * JustifiedPhotoLayout.itemSpacing
        try require(abs(firstWidth - 600) < 0.01, "Blocksatzzeile schließt nicht bündig ab")
        try require(rows[1].imageHeight == 150, "Letzte Blocksatzzeile wurde unnötig vergrößert")
    }

    private static func checkLastSelectedFolder() async throws {
        try await withTemporaryDirectory { root in
            let sourceURL = root.appendingPathComponent("Quelle", isDirectory: true)
            let childURL = sourceURL.appendingPathComponent("Unterordner", isDirectory: true)
            let outsideURL = root.appendingPathComponent("Andere Quelle", isDirectory: true)
            try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)

            let suiteName = "RAWViewerTests.FolderLocation.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw CheckFailure(message: "Test-UserDefaults konnten nicht angelegt werden")
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let locationStore = FolderLocationStore(defaults: defaults)
            let source = PhotoSource(url: sourceURL)

            locationStore.saveFolder(childURL)
            try require(
                locationStore.loadFolder(in: [source]) == childURL.standardizedFileURL,
                "Gespeicherter Unterordner wurde nicht wiederhergestellt"
            )

            locationStore.saveFolder(outsideURL)
            try require(
                locationStore.loadFolder(in: [source]) == nil,
                "Ordner außerhalb einer Fotoquelle wurde wiederhergestellt"
            )

            locationStore.saveFolder(childURL)
            locationStore.clearFolder(ifInside: sourceURL)
            try require(
                defaults.string(forKey: PreferenceKeys.lastSelectedFolderPath) == nil,
                "Entfernte Fotoquelle blieb als letzter Ordner gespeichert"
            )
        }
    }

    private static func checkCancellation() async throws {
        try await withTemporaryDirectory { root in
            touch(root.appendingPathComponent("photo.jpg"))
            let task = Task { try await PhotoScanner().scan(folderURL: root) }
            task.cancel()
            do {
                _ = try await task.value
                throw CheckFailure(message: "Abgebrochener Scan lieferte ein Ergebnis")
            } catch is CancellationError {
                return
            }
        }
    }

    private static func checkSmallStandardRendering() async throws {
        try await withTemporaryDirectory { root in
            let url = root.appendingPathComponent("pixel.png")
            try writeTinyPNG(to: url)
            let rendered = try await FullImageService().render(url: url, isRAW: false, maxPixelSize: 2_048)
            try require(rendered.pixelSize.width == 1 && rendered.pixelSize.height == 1, "Kleines PNG wurde falsch skaliert")
        }
    }

    private static func checkImageMetadata() async throws {
        try await withTemporaryDirectory { root in
            let url = root.appendingPathComponent("metadata.png")
            try writeTinyPNG(to: url)
            let metadata = ImageMetadataReader.metadata(at: url)
            try require(metadata.pixelWidth == 1 && metadata.pixelHeight == 1, "Bildabmessungen fehlen")
            let metadataWithCaptureDate = PhotoMetadata(captureDate: Date(timeIntervalSince1970: 0))
            try require(
                metadataWithCaptureDate.rows.contains { $0.label == "Aufnahmedatum" && !$0.value.isEmpty },
                "Aufnahmedatum wird nicht angezeigt"
            )
            try require(
                PhotoMetadata.exposureTimeLabel(1.0 / 250.0) == "1/250",
                "Belichtungszeit wird nicht als Bruch formatiert"
            )
        }
    }

    private static func checkJPEGExport() async throws {
        try await withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source.png")
            let destination = root.appendingPathComponent("export.jpg")
            try writePNG(width: 2, height: 1, to: source)
            let date = Date(timeIntervalSince1970: 100)
            let asset = PhotoAsset(
                id: source.path,
                rawURL: nil,
                companionURLs: [],
                standaloneURL: source,
                captureDate: date,
                modificationDate: date,
                filename: source.lastPathComponent
            )
            try await PhotoExportService().write(asset, format: .jpeg, rotation: .right, to: destination)
            let metadata = ImageMetadataReader.metadata(at: destination)
            try require(metadata.pixelWidth == 1 && metadata.pixelHeight == 2, "JPEG-Export wurde nicht nach rechts gedreht")
            try require(ImageMetadataReader.orientation(at: destination) == 1, "JPEG-Export enthält keine normalisierte Orientierung")

            let rawURL = root.appendingPathComponent("original.CR3")
            let rawData = Data([0x52, 0x41, 0x57])
            try rawData.write(to: rawURL)
            let sourceSidecar = rawURL.deletingPathExtension().appendingPathExtension("xmp")
            let sidecarData = Data("<xmpmeta>rotation</xmpmeta>".utf8)
            try sidecarData.write(to: sourceSidecar)
            let rawAsset = PhotoAsset(
                id: "raw:" + rawURL.path,
                rawURL: rawURL,
                companionURLs: [],
                standaloneURL: nil,
                captureDate: date,
                modificationDate: date,
                filename: rawURL.lastPathComponent
            )
            let rawDestination = root.appendingPathComponent("copy.CR3")
            try await PhotoExportService().write(rawAsset, format: .original, to: rawDestination)
            let copiedSidecar = rawDestination.deletingPathExtension().appendingPathExtension("xmp")
            let copiedRawData = try Data(contentsOf: rawDestination)
            let copiedSidecarData = try Data(contentsOf: copiedSidecar)
            try require(copiedRawData == rawData, "Originalexport ist nicht bytegenau")
            try require(copiedSidecarData == sidecarData, "Originalexport hat das RAW-Sidecar nicht mitgenommen")

            let blockedDestination = root.appendingPathComponent("blocked.CR3")
            let blockedSidecar = blockedDestination.deletingPathExtension().appendingPathExtension("xmp")
            try Data("bestehend".utf8).write(to: blockedSidecar)
            do {
                try await PhotoExportService().write(rawAsset, format: .original, to: blockedDestination)
                throw CheckFailure(message: "Vorhandenes Ziel-Sidecar wurde beim Originalexport akzeptiert")
            } catch is PhotoExportError {
                try require(!FileManager.default.fileExists(atPath: blockedDestination.path), "Bild wurde trotz Sidecar-Konflikt exportiert")
            }
        }
    }

    private static func checkPhotoRotation() async throws {
        try require(PhotoRotation.none.rotatedRight() == .right, "Rechtsdrehung aus der Ausgangslage ist falsch")
        try require(PhotoRotation.right.rotatedRight() == .upsideDown, "Zweite Rechtsdrehung ist falsch")
        try require(PhotoRotation.none.rotatedLeft() == .left, "Linksdrehung aus der Ausgangslage ist falsch")
        try require(PhotoRotation.left.rotatedRight() == .none, "Gegensätzliche Drehungen heben sich nicht auf")
        try require(PhotoRotation.right.adjustedAspectRatio(1.5) == 2.0 / 3.0, "Gedrehtes Seitenverhältnis ist falsch")
        try require(PhotoRotation.right.applying(toTIFFOrientation: 1) == 6, "TIFF-Orientierung 1 wurde falsch gedreht")
        try require(PhotoRotation.right.applying(toTIFFOrientation: 6) == 3, "TIFF-Orientierung 6 wurde falsch gedreht")
        try require(PhotoRotation.right.applying(toTIFFOrientation: 2) == 7, "Gespiegelte TIFF-Orientierung wurde falsch gedreht")
        let expectedRightRotations = [6, 7, 8, 5, 2, 3, 4, 1]
        for orientation in 1...8 {
            try require(
                PhotoRotation.right.applying(toTIFFOrientation: orientation) == expectedRightRotations[orientation - 1],
                "TIFF-Orientierung \(orientation) wurde nicht korrekt zusammengesetzt"
            )
        }

        try await withTemporaryDirectory { root in
            let cache = root.appendingPathComponent("Cache", isDirectory: true)
            let folder = root.appendingPathComponent("Fotos", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("gedreht.jpg")
            touch(source)
            let edit = PhotoRotationEdit(
                photoID: "file:" + source.path,
                sourcePath: source.path,
                rotation: .right,
                originalXMPOrientation: nil,
                isOriginalXMPOrientationKnown: true,
                isXMPSyncPending: false,
                xmpSyncError: nil,
                updatedAt: Date(timeIntervalSince1970: 321)
            )
            let catalog = PhotoCatalog()
            try await catalog.configure(cacheDirectory: cache)
            try await catalog.saveRotationEdit(edit)
            let stored = try await catalog.rotationEdits(in: folder)
            try require(stored == [edit], "Drehung wurde nicht im Katalog gespeichert")
            try await catalog.removeAllFiles()
            let afterIndexReset = try await catalog.rotationEdits(in: folder)
            try require(afterIndexReset == [edit], "Index-Neuaufbau hat die Drehung gelöscht")
            try await catalog.deleteRotationEdit(photoID: edit.photoID)
            let afterDelete = try await catalog.rotationEdits(in: folder)
            try require(afterDelete.isEmpty, "Zurückgesetzte Drehung blieb im Katalog")
        }
    }

    private static func checkPhotoCatalog() async throws {
        try await withTemporaryDirectory { root in
            let cache = root.appendingPathComponent("Cache", isDirectory: true)
            let photos = root.appendingPathComponent("Fotos", isDirectory: true)
            let child = photos.appendingPathComponent("Unterordner", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            touch(photos.appendingPathComponent("root.jpg"))
            touch(child.appendingPathComponent("child.jpg"))

            let scanner = PhotoScanner()
            let result = try await scanner.scan(folderURL: photos, cachedFiles: [])
            let catalog = PhotoCatalog()
            try await catalog.configure(cacheDirectory: cache)
            try await catalog.replaceFiles(in: photos, with: result.indexedFiles)

            let all = try await catalog.files(in: photos)
            let nested = try await catalog.files(in: child)
            let indexedCount = try await catalog.indexedFileCount()
            try require(all.count == 2, "Fotoindex enthält nicht beide Dateien")
            try require(nested.map { $0.url.lastPathComponent } == ["child.jpg"], "Ordnerabfrage des Fotoindex ist falsch")
            try require(indexedCount == 2, "Anzahl im Fotoindex ist falsch")

            let addedURL = child.appendingPathComponent("added.png")
            touch(addedURL)
            let added = try await scanner.indexedFile(at: addedURL, cachedFile: nil)
            try require(added != nil, "Einzelne Indexaktualisierung hat die neue Datei nicht erkannt")
            try await catalog.upsertFiles([added].compactMap { $0 })
            try await catalog.removePathsAndDescendants([child.appendingPathComponent("child.jpg").path])
            let updated = try await catalog.files(in: child)
            try require(updated.map { $0.url.lastPathComponent } == ["added.png"], "Inkrementelle Indexaktualisierung ist falsch")
        }
    }

    private static func checkMetadataReuse() async throws {
        try await withTemporaryDirectory { root in
            touch(root.appendingPathComponent("cached.jpg"))
            let scanner = PhotoScanner()
            let first = try await scanner.scan(folderURL: root, cachedFiles: [])
            let second = try await scanner.scan(folderURL: root, cachedFiles: first.indexedFiles)
            try require(second.reusedMetadataCount == 1, "Unveränderte Metadaten wurden erneut gelesen")
            try require(first.assets == second.assets, "Cache-Wiederverwendung verändert Fotoeinträge")
        }
    }

    private static func checkPhotoAnalysisCatalog() async throws {
        try await withTemporaryDirectory { root in
            let cache = root.appendingPathComponent("Cache", isDirectory: true)
            let folder = root.appendingPathComponent("Fotos", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let imageURL = folder.appendingPathComponent("analysiert.jpg")
            touch(imageURL)
            let date = Date(timeIntervalSince1970: 123)
            let asset = PhotoAsset(
                id: "file:" + imageURL.path,
                rawURL: nil,
                companionURLs: [],
                standaloneURL: imageURL,
                captureDate: date,
                modificationDate: date,
                filename: imageURL.lastPathComponent
            )
            let analysis = PhotoAnalysis(
                photoID: asset.id,
                sourcePath: imageURL.path,
                sourceModificationDate: date,
                modelIdentifier: "test/vision-model",
                keywords: ["landschaft", "sonnenuntergang"],
                description: "Eine Landschaft im warmen Abendlicht.",
                analyzedAt: Date(timeIntervalSince1970: 456)
            )

            let catalog = PhotoCatalog()
            try await catalog.configure(cacheDirectory: cache)
            try await catalog.saveAnalysis(analysis)
            let loaded = try await catalog.analyses(in: folder)
            let analysisCount = try await catalog.analysisCount()
            try require(loaded == [analysis], "Gespeicherte Schlagwörter wurden nicht korrekt geladen")
            try require(loaded[0].matches(asset), "Gültige Fotoanalyse wurde als veraltet erkannt")
            try require(analysisCount == 1, "Analysezähler ist falsch")

            let export = XMPExportRecord(
                photoID: asset.id,
                sourcePath: asset.primaryURL.standardizedFileURL.path,
                keywordsJSON: analysis.keywordsJSON,
                sidecarPath: folder.appendingPathComponent("analysiert.xmp").path,
                exportedAt: Date(timeIntervalSince1970: 789)
            )
            try await catalog.saveXMPExport(export)
            let storedExports = try await catalog.xmpExports(in: folder)
            try require(storedExports == [export], "XMP-Exportstatus wurde nicht gespeichert")
            try await catalog.saveAnalysis(analysis)
            let resetExports = try await catalog.xmpExports(in: folder)
            try require(resetExports.isEmpty, "Neue Analyse hat alten XMP-Exportstatus nicht zurückgesetzt")
            try await catalog.saveXMPExport(export)

            try await catalog.removePathsAndDescendants([imageURL.path])
            let analysesAfterRemoval = try await catalog.analyses(in: folder)
            try require(analysesAfterRemoval.isEmpty, "Analyse einer gelöschten Datei blieb im Index")
            let exportsAfterRemoval = try await catalog.xmpExports(in: folder)
            try require(exportsAfterRemoval.isEmpty, "XMP-Exportstatus einer gelöschten Analyse blieb im Index")
        }
    }

    private static func checkLegacyCatalogMigration() async throws {
        try await withTemporaryDirectory { root in
            let cache = root.appendingPathComponent("Cache", isDirectory: true)
            let folder = root.appendingPathComponent("Fotos", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = folder.appendingPathComponent("alt.cr3")
            touch(image)
            let databaseURL = cache.appendingPathComponent("index.sqlite")
            var databaseHandle: OpaquePointer?
            guard sqlite3_open(databaseURL.path, &databaseHandle) == SQLITE_OK, let database = databaseHandle else {
                throw CheckFailure(message: "Alte Testdatenbank konnte nicht erstellt werden")
            }
            let escapedPath = image.path.replacingOccurrences(of: "'", with: "''")
            let escapedSidecar = image.deletingPathExtension().appendingPathExtension("xmp").path.replacingOccurrences(of: "'", with: "''")
            let sql = """
                CREATE TABLE photo_analysis (
                    photo_id TEXT PRIMARY KEY NOT NULL,
                    source_path TEXT NOT NULL,
                    source_modification_date REAL NOT NULL,
                    model_identifier TEXT NOT NULL,
                    keywords_json TEXT NOT NULL,
                    description TEXT NOT NULL,
                    analyzed_at REAL NOT NULL
                );
                CREATE TABLE xmp_exports (
                    photo_id TEXT PRIMARY KEY NOT NULL,
                    keywords_json TEXT NOT NULL,
                    sidecar_path TEXT NOT NULL,
                    exported_at REAL NOT NULL,
                    FOREIGN KEY(photo_id) REFERENCES photo_analysis(photo_id) ON DELETE CASCADE
                );
                INSERT INTO photo_analysis VALUES ('legacy', '\(escapedPath)', 100, 'legacy-model', '["Alt"]', 'Altbestand', 101);
                INSERT INTO xmp_exports VALUES ('legacy', '["Alt"]', '\(escapedSidecar)', 102);
                """
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "Unbekannter SQLite-Fehler"
                sqlite3_free(error)
                sqlite3_close(database)
                throw CheckFailure(message: "Alte Testdatenbank ist ungültig: \(message)")
            }
            sqlite3_close(database)

            let catalog = PhotoCatalog()
            try await catalog.configure(cacheDirectory: cache)
            let analyses = try await catalog.analyses(in: folder)
            let exports = try await catalog.xmpExports(in: folder)
            try require(analyses.count == 1 && analyses.first?.photoID == "legacy", "Bestehende KI-Analyse ging bei der Migration verloren")
            try require(exports.count == 1 && exports.first?.sourcePath == image.path, "Bestehender XMP-Exportstand ging bei der Migration verloren")
        }
    }

    private static func checkXMPSidecars() async throws {
        try await withTemporaryDirectory { root in
            let rawURL = root.appendingPathComponent("IMG_0001.CR3")
            touch(rawURL)
            let date = Date(timeIntervalSince1970: 123)
            let asset = PhotoAsset(
                id: "raw:" + rawURL.path,
                rawURL: rawURL,
                companionURLs: [],
                standaloneURL: nil,
                captureDate: date,
                modificationDate: date,
                filename: rawURL.lastPathComponent
            )
            let service = XMPSidecarService()

            let created = try service.writeKeywords(["landschaft", "Abendlicht"], for: asset)
            let sidecarURL = created.url
            try require(sidecarURL.lastPathComponent == "IMG_0001.xmp", "XMP-Dateiname stimmt nicht mit dem RAW überein")
            let createdXML = try String(contentsOf: sidecarURL, encoding: .utf8)
            try require(createdXML.contains("landschaft") && createdXML.contains("Abendlicht"), "Neue XMP-Schlagwörter fehlen")

            let existingXML = """
                <?xml version="1.0" encoding="UTF-8"?>
                <x:xmpmeta xmlns:x="adobe:ns:meta/">
                  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                    <rdf:Description rdf:about=""
                        xmlns:dc="http://purl.org/dc/elements/1.1/"
                        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
                        crs:Exposure2012="0.50">
                      <dc:subject><rdf:Bag><rdf:li>manuell</rdf:li></rdf:Bag></dc:subject>
                    </rdf:Description>
                  </rdf:RDF>
                </x:xmpmeta>
                """
            try Data(existingXML.utf8).write(to: sidecarURL, options: .atomic)
            let updated = try service.writeKeywords(["Manuell", "sonnenuntergang"], for: asset)
            if case .updated = updated {} else {
                throw CheckFailure(message: "Vorhandenes XMP wurde nicht ergänzt")
            }
            let mergedXML = try String(contentsOf: sidecarURL, encoding: .utf8)
            try require(mergedXML.contains("crs:Exposure2012=\"0.50\""), "Bestehende Lightroom-Metadaten wurden verworfen")
            try require(mergedXML.contains("manuell") && mergedXML.contains("sonnenuntergang"), "Manuelle und neue Schlagwörter wurden nicht zusammengeführt")
            try require(mergedXML.components(separatedBy: ">manuell<").count == 2, "Schlagwort wurde doppelt geschrieben")

            _ = try service.writeOrientation(6, for: asset)
            let storedOrientation = try service.orientation(for: asset)
            try require(storedOrientation == 6, "XMP-Orientierung wurde nicht gespeichert")
            let orientedXML = try String(contentsOf: sidecarURL, encoding: .utf8)
            try require(orientedXML.contains("tiff:Orientation=\"6\""), "Standardfeld tiff:Orientation fehlt")
            try require(orientedXML.contains("crs:Exposure2012=\"0.50\""), "Drehung hat Lightroom-Metadaten verworfen")
            _ = try service.writeOrientation(nil, for: asset)
            let resetOrientation = try service.orientation(for: asset)
            try require(resetOrientation == nil, "Zurücksetzen hat die XMP-Orientierung nicht entfernt")

            let unchanged = try service.writeKeywords(["sonnenuntergang"], for: asset)
            if case .unchanged = unchanged {} else {
                throw CheckFailure(message: "Unverändertes XMP wurde unnötig neu geschrieben")
            }

            _ = try service.writeKeywords(["sonnenuntergang", "Person: Alter Name"], for: asset)
            _ = try service.writeKeywords(
                ["sonnenuntergang", "Person: Neuer Name"],
                replacingPersonKeywords: ["sonnenuntergang", "Person: Alter Name"],
                for: asset
            )
            let renamedXML = try String(contentsOf: sidecarURL, encoding: .utf8)
            try require(!renamedXML.contains("Person: Alter Name"), "Umbenanntes Personenschlagwort blieb im XMP erhalten")
            try require(renamedXML.contains("Person: Neuer Name"), "Neues Personenschlagwort fehlt im XMP")
            _ = try service.writeKeywords(
                [],
                replacingPersonKeywords: ["Person: Neuer Name"],
                for: asset
            )
            let clearedXML = try String(contentsOf: sidecarURL, encoding: .utf8)
            try require(!clearedXML.contains("Person: Neuer Name"), "Aufgehobene Personenzuordnung blieb im XMP erhalten")
            try require(clearedXML.contains("sonnenuntergang"), "Fremdes XMP-Schlagwort wurde beim Entfernen einer Person gelöscht")

            let unsafeXML = "<!DOCTYPE x [<!ENTITY external SYSTEM \"file:///etc/passwd\">]><x/>"
            try Data(unsafeXML.utf8).write(to: sidecarURL, options: .atomic)
            do {
                _ = try service.writeKeywords(["sicher"], for: asset)
                throw CheckFailure(message: "Unsichere XMP-Entity wurde akzeptiert")
            } catch is XMPSidecarError {
                // Expected.
            }
            let preservedUnsafeXML = try String(contentsOf: sidecarURL, encoding: .utf8)
            try require(preservedUnsafeXML == unsafeXML, "Unsicheres XMP wurde verändert")

            let dngURL = root.appendingPathComponent("IMG_0002.DNG")
            touch(dngURL)
            let dngAsset = PhotoAsset(
                id: "raw:" + dngURL.path,
                rawURL: dngURL,
                companionURLs: [],
                standaloneURL: nil,
                captureDate: date,
                modificationDate: date,
                filename: dngURL.lastPathComponent
            )
            try require(service.sidecarURL(for: dngAsset) == nil, "DNG wurde fälschlich als externes Sidecar-Ziel akzeptiert")
        }
    }

    private static func checkLMStudioConfiguration() async throws {
        try require(LMStudioPhotoAnalysisProfile.contextLength == 16_384, "Das LM-Studio-Profil verwendet eine falsche Kontextlänge")
        try require(LMStudioPhotoAnalysisProfile.temperature == 0.1, "Das LM-Studio-Profil verwendet eine falsche Temperatur")
        try require(LMStudioPhotoAnalysisProfile.topP == 0.8, "Das LM-Studio-Profil verwendet einen falschen Top-P-Wert")
        try require(LMStudioPhotoAnalysisProfile.topK == 20, "Das LM-Studio-Profil verwendet einen falschen Top-K-Wert")
        try require(LMStudioPhotoAnalysisProfile.minP == 0.0, "Das LM-Studio-Profil verwendet einen falschen Min-P-Wert")
        try require(LMStudioPhotoAnalysisProfile.repeatPenalty == 1.0, "Das LM-Studio-Profil verwendet eine falsche Wiederholungsstrafe")
        try require(LMStudioPhotoAnalysisProfile.maxOutputTokens == 2_048, "Das LM-Studio-Profil verwendet ein falsches Ausgabelimit")

        let local = LMStudioConfiguration(
            serverAddress: "http://127.0.0.1:1234/",
            modelIdentifier: "test/vision",
            autoStartLocalServer: true,
            unloadAfterAnalysis: true
        )
        let normalizedLocalURL = try local.serverURL
        try require(normalizedLocalURL.absoluteString == "http://127.0.0.1:1234", "Lokale Server-Adresse wird falsch normalisiert")
        try require(local.isLocalServer, "Loopback-Adresse wird nicht als lokaler Server erkannt")

        let remote = LMStudioConfiguration(
            serverAddress: "https://llm.example.test:1234",
            modelIdentifier: "test/vision",
            autoStartLocalServer: true,
            unloadAfterAnalysis: true
        )
        try require(!remote.isLocalServer, "Entfernter Server wird fälschlich als lokal erkannt")

        let invalid = LMStudioConfiguration(
            serverAddress: "file:///tmp/lmstudio",
            modelIdentifier: "test/vision",
            autoStartLocalServer: true,
            unloadAfterAnalysis: true
        )
        do {
            _ = try invalid.serverURL
            throw CheckFailure(message: "Unsichere Server-Adresse wurde akzeptiert")
        } catch is LMStudioError {
            // Expected.
        }
    }

    private static func checkThumbnailBuckets() async throws {
        try require(ThumbnailService.pixelBucket(for: 100) == 1_024, "Kleine Ansicht verwendet nicht den 1024er Cache")
        try require(ThumbnailService.pixelBucket(for: 400) == 1_024, "Mittlere Ansicht verwendet nicht den 1024er Cache")
        try require(ThumbnailService.pixelBucket(for: 1_600) == 1_024, "Große Ansicht verwendet nicht den 1024er Cache")

        try await withTemporaryDirectory { root in
            let cache = root.appendingPathComponent("Cache", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let imageURL = root.appendingPathComponent("thumbnail.png")
            try writeTinyPNG(to: imageURL)
            let values = try imageURL.resourceValues(forKeys: [.contentModificationDateKey])
            let date = values.contentModificationDate ?? .distantPast
            let asset = PhotoAsset(
                id: imageURL.path,
                rawURL: nil,
                companionURLs: [],
                standaloneURL: imageURL,
                captureDate: date,
                modificationDate: date,
                filename: imageURL.lastPathComponent
            )
            let service = ThumbnailService()
            try await service.configure(cacheDirectory: cache, sizeLimitGB: 2)
            let rendered = await service.thumbnail(for: asset, requestedPixelSize: 256, scale: 2)
            let smallView = await service.thumbnail(for: asset, requestedPixelSize: 100, scale: 1)
            let largeView = await service.thumbnail(for: asset, requestedPixelSize: 1_600, scale: 1)
            let cachedIDs = await service.cachedAssetIDs(for: [asset], requestedPixelSize: 256)
            let stats = await service.statistics()
            try require(rendered != nil, "Test-Vorschaubild konnte nicht erzeugt werden")
            try require(smallView != nil && largeView != nil, "1024er Vorschau wird nicht für alle Ansichtsgrößen wiederverwendet")
            try require(cachedIDs == [asset.id], "Erzeugtes Vorschaubild wurde nicht im Cache erkannt")
            try require(
                service.cachedAspectRatio(for: asset, requestedPixelSize: 256) == 1,
                "Seitenverhältnis wurde nicht aus dem Thumbnail-Cache gelesen"
            )
            try require(stats.fileCount == 1 && stats.byteCount > 0, "Ansichtsgrößen erzeugen mehr als eine Cachedatei")
        }
    }

    private static func checkTenThousandFiles() async throws {
        try await withTemporaryDirectory { root in
            for index in 0..<10_000 {
                touch(root.appendingPathComponent(String(format: "IMG_%05d.jpg", index)))
            }
            let photos = try await PhotoScanner().scan(folderURL: root)
            try require(photos.count == 10_000, "Erwartet 10.000 Einträge, erhalten: \(photos.count)")
            try require(Set(photos.map(\.id)).count == 10_000, "IDs sind im Lasttest nicht eindeutig")
        }
    }

    private static func asset(name: String, date: Date) -> PhotoAsset {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return PhotoAsset(
            id: url.path,
            rawURL: nil,
            companionURLs: [],
            standaloneURL: url,
            captureDate: date,
            modificationDate: date,
            filename: name
        )
    }

    private static func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RAWViewerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    private static func touch(_ url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    private static func writeTinyPNG(to url: URL) throws {
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        guard let data = Data(base64Encoded: encoded) else {
            throw CheckFailure(message: "PNG-Testdaten ungültig")
        }
        try data.write(to: url)
    }

    private static func writePNG(width: Int, height: Int, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CheckFailure(message: "PNG-Testbild konnte nicht erzeugt werden") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CheckFailure(message: "PNG-Testbild konnte nicht geschrieben werden")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(message: message) }
    }
}
