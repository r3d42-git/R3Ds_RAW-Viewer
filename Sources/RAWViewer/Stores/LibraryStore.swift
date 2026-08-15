import Foundation
import Combine
@preconcurrency import AppKit

struct ViewerActionError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct LargePhotoSourceWarning: Identifiable {
    let id = UUID()
    let urls: [URL]
    let oversizedFolders: [URL]

    var message: String {
        let limit = PhotoFolderSizeChecker.recommendedPhotoLimit.formatted(.number.grouping(.automatic))
        if oversizedFolders.count == 1, let folder = oversizedFolders.first {
            return "Der Ordner „\(folder.lastPathComponent)“ enthält einschließlich seiner Unterordner mehr als \(limit) Fotos. Bei dieser Größe kann RAW Viewer spürbar langsamer reagieren. Möchtest du ihn trotzdem hinzufügen?"
        }
        let names = oversizedFolders.map { "• \($0.lastPathComponent)" }.joined(separator: "\n")
        return "Diese Ordner enthalten einschließlich ihrer Unterordner jeweils mehr als \(limit) Fotos:\n\n\(names)\n\nBei dieser Größe kann RAW Viewer spürbar langsamer reagieren. Möchtest du sie trotzdem hinzufügen?"
    }
}

struct XMPExportSuggestion: Identifiable {
    let id = UUID()
    let photoIDs: Set<PhotoAsset.ID>

    var photoCount: Int {
        photoIDs.count
    }

    var message: String {
        if photoCount == 1 {
            return "Die KI-Verschlagwortung ist abgeschlossen. Soll für das eben verschlagwortete RAW-Foto jetzt eine .xmp-Datei neben dem Original angelegt werden?"
        }
        return "Die KI-Verschlagwortung ist abgeschlossen. Soll für die \(photoCount) eben verschlagworteten RAW-Fotos jetzt jeweils eine .xmp-Datei neben dem Original angelegt werden?"
    }
}

struct ViewerCacheStats: Sendable {
    let indexedFileCount: Int
    let analyzedPhotoCount: Int
    let storedPersonDataCount: Int
    let thumbnailFileCount: Int
    let thumbnailByteCount: Int64

    static let empty = ViewerCacheStats(
        indexedFileCount: 0,
        analyzedPhotoCount: 0,
        storedPersonDataCount: 0,
        thumbnailFileCount: 0,
        thumbnailByteCount: 0
    )

    var formattedThumbnailSize: String {
        ByteCountFormatter.string(fromByteCount: thumbnailByteCount, countStyle: .file)
    }
}

enum PhotoExportPhase: Sendable {
    case idle
    case exporting
    case complete
}

struct PhotoExportProgress: Sendable {
    let phase: PhotoExportPhase
    let total: Int
    let completed: Int
    let failed: Int

    static let idle = PhotoExportProgress(phase: .idle, total: 0, completed: 0, failed: 0)
}

enum ThumbnailPreparationPhase: Sendable {
    case idle
    case checking
    case rendering
    case complete
}

struct ThumbnailPreparationProgress: Sendable {
    let phase: ThumbnailPreparationPhase
    let total: Int
    let checked: Int
    let ready: Int
    let failed: Int

    static let idle = ThumbnailPreparationProgress(phase: .idle, total: 0, checked: 0, ready: 0, failed: 0)

    var progressValue: Double {
        switch phase {
        case .idle: 0
        case .checking: Double(checked)
        case .rendering, .complete: Double(ready + failed)
        }
    }
}

@MainActor
final class ThumbnailPreparationState: ObservableObject {
    @Published private(set) var progress = ThumbnailPreparationProgress.idle

    func update(_ progress: ThumbnailPreparationProgress) {
        self.progress = progress
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var sources: [PhotoSource]
    @Published var selectedFolderURL: URL?
    @Published var folderChildren: [String: [FolderItem]] = [:]
    @Published var loadingFolders: Set<String> = []
    @Published var photos: [PhotoAsset] = []
    @Published private(set) var photoSelection = PhotoSelection()
    @Published var viewMode: LibraryViewMode = .grid
    @Published var isScanning = false
    @Published var scanError: String?
    @Published var sortOrder: PhotoSortOrder
    @Published var viewerZoom = 1.0
    @Published var viewerFitsWindow = true
    @Published var isExporting = false
    @Published private(set) var photoExportProgress = PhotoExportProgress.idle
    @Published var actionError: ViewerActionError?
    @Published private(set) var isCheckingSourceSize = false
    @Published var largePhotoSourceWarning: LargePhotoSourceWarning?
    @Published var xmpExportSuggestion: XMPExportSuggestion?
    @Published private(set) var softwareUpdateStatus: SoftwareUpdateStatus = .idle
    @Published var softwareUpdatePrompt: SoftwareUpdate?
    @Published private(set) var preparedSoftwareUpdate: PreparedSoftwareUpdate?
    @Published var preparedSoftwareUpdatePrompt: PreparedSoftwareUpdate?
    @Published private(set) var isCacheConfigured = false
    @Published private(set) var isConfiguringCache = false
    @Published private(set) var cacheDirectoryURL: URL?
    @Published private(set) var cacheStats = ViewerCacheStats.empty
    @Published var cacheSetupError: String?
    @Published var searchText = ""
    @Published private(set) var analysesByPhotoID: [PhotoAsset.ID: PhotoAnalysis] = [:]
    @Published private(set) var xmpExportsByPhotoID: [PhotoAsset.ID: XMPExportRecord] = [:]
    @Published private(set) var rotationEditsByPhotoID: [PhotoAsset.ID: PhotoRotationEdit] = [:]
    @Published private(set) var analysisProgress = PhotoAnalysisProgress.idle
    @Published private(set) var xmpExportProgress = XMPExportProgress.idle
    @Published private(set) var analyzingPhotoID: PhotoAsset.ID?
    @Published private(set) var lmStudioStatus = LMStudioRuntimeStatus.unknown
    @Published private(set) var isLMStudioBusy = false

    let thumbnailService: ThumbnailService
    let thumbnailPreparation = ThumbnailPreparationState()
    private let scanner: PhotoScanner
    private let folderSizeChecker: PhotoFolderSizeChecker
    private let bookmarkStore: BookmarkStore
    private let folderLocationStore: FolderLocationStore
    private let cacheLocationStore: CacheLocationStore
    private let catalog: PhotoCatalog
    private let fullImageService: FullImageService
    private let exportService: PhotoExportService
    private let lmStudioService: LMStudioService
    private let xmpSidecarService: XMPSidecarService
    private let softwareUpdateService: SoftwareUpdateService
    private var scanTask: Task<Void, Never>?
    private var sourceSizeCheckTask: Task<Void, Never>?
    private var thumbnailPreparationTask: Task<Void, Never>?
    private var folderTasks: [String: Task<Void, Never>] = [:]
    private var watcher: FolderWatcher?
    private var watchedPath: String?
    private var didPrepareCache = false
    private var scanGeneration = UUID()
    private var thumbnailPreparationGeneration = UUID()
    private var preparedThumbnailKey: String?
    private var analysisTask: Task<Void, Never>?
    private var xmpExportTask: Task<Void, Never>?
    private var rotationPersistenceTask: Task<Void, Never>?
    private var softwareUpdateCheckTask: Task<Void, Never>?
    private var softwareUpdateDownloadTask: Task<Void, Never>?
    private var pendingRotationAssets: [PhotoAsset.ID: PhotoAsset] = [:]
    private var didCheckLMStudio = false
    private var didCheckSoftwareUpdate = false

    init(
        scanner: PhotoScanner = PhotoScanner(),
        folderSizeChecker: PhotoFolderSizeChecker = PhotoFolderSizeChecker(),
        bookmarkStore: BookmarkStore = BookmarkStore(),
        folderLocationStore: FolderLocationStore = FolderLocationStore(),
        thumbnailService: ThumbnailService = ThumbnailService(),
        cacheLocationStore: CacheLocationStore = CacheLocationStore(),
        catalog: PhotoCatalog = PhotoCatalog(),
        fullImageService: FullImageService = FullImageService(),
        exportService: PhotoExportService = PhotoExportService(),
        lmStudioService: LMStudioService = LMStudioService(),
        xmpSidecarService: XMPSidecarService = XMPSidecarService(),
        softwareUpdateService: SoftwareUpdateService = SoftwareUpdateService()
    ) {
        self.scanner = scanner
        self.folderSizeChecker = folderSizeChecker
        self.bookmarkStore = bookmarkStore
        self.folderLocationStore = folderLocationStore
        self.thumbnailService = thumbnailService
        self.cacheLocationStore = cacheLocationStore
        self.catalog = catalog
        self.fullImageService = fullImageService
        self.exportService = exportService
        self.lmStudioService = lmStudioService
        self.xmpSidecarService = xmpSidecarService
        self.softwareUpdateService = softwareUpdateService
        self.sources = bookmarkStore.loadSources()
        let savedSort = UserDefaults.standard.string(forKey: PreferenceKeys.sortOrder)
        self.sortOrder = PhotoSortOrder(rawValue: savedSort ?? "") ?? .newestFirst

    }

    func prepareCacheIfNeeded() async {
        guard !didPrepareCache else { return }
        didPrepareCache = true
        if let savedURL = cacheLocationStore.load() {
            do {
                try await activateCache(at: savedURL, persist: false)
                return
            } catch {
                cacheSetupError = error.localizedDescription
            }
        }
        await chooseCacheLocation()
    }

    func chooseCacheLocation() async {
        guard !isConfiguringCache else { return }
        let selectedURL = FolderPanelService.chooseCacheDirectory(currentURL: cacheDirectoryURL)
        guard let selectedURL else { return }
        isConfiguringCache = true
        cacheSetupError = nil
        defer { isConfiguringCache = false }
        do {
            try await activateCache(at: selectedURL, persist: true)
        } catch {
            cacheSetupError = error.localizedDescription
            actionError = ViewerActionError(title: "Cache nicht verfügbar", message: error.localizedDescription)
        }
    }

    func updateCacheSizeLimit(_ gigabytes: Int) {
        thumbnailService.updateSizeLimit(gigabytes: gigabytes)
    }

    func revealCacheInFinder() {
        guard let cacheDirectoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([cacheDirectoryURL])
    }

    var currentSoftwareVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unbekannt"
    }

    func checkForSoftwareUpdateAtLaunch() {
        guard !didCheckSoftwareUpdate else { return }
        didCheckSoftwareUpdate = true
        checkForSoftwareUpdate(showErrors: false)
    }

    func checkForSoftwareUpdate(showErrors: Bool = true) {
        guard softwareUpdateCheckTask == nil,
              softwareUpdateDownloadTask == nil,
              preparedSoftwareUpdate == nil else { return }
        guard let currentVersion = SemanticVersion(string: currentSoftwareVersion) else {
            if showErrors {
                actionError = ViewerActionError(
                    title: "Update-Prüfung nicht möglich",
                    message: "Die Versionsnummer dieser App ist ungültig."
                )
            }
            return
        }

        softwareUpdateStatus = .checking
        let service = softwareUpdateService
        softwareUpdateCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let update = try await service.fetchLatestUpdate(currentVersion: currentVersion)
                guard !Task.isCancelled else { return }
                if let update {
                    softwareUpdateStatus = .available(update)
                    softwareUpdatePrompt = update
                } else {
                    softwareUpdateStatus = .upToDate
                }
            } catch {
                guard !Task.isCancelled else { return }
                softwareUpdateStatus = .failed(error.localizedDescription)
                if showErrors {
                    actionError = ViewerActionError(title: "Update-Prüfung fehlgeschlagen", message: error.localizedDescription)
                }
            }
            softwareUpdateCheckTask = nil
        }
    }

    func dismissSoftwareUpdatePrompt() {
        softwareUpdatePrompt = nil
    }

    func downloadSoftwareUpdate(_ update: SoftwareUpdate) {
        guard softwareUpdateDownloadTask == nil,
              softwareUpdateCheckTask == nil,
              preparedSoftwareUpdate == nil else { return }
        softwareUpdatePrompt = nil
        softwareUpdateStatus = .downloading(update)
        let service = softwareUpdateService
        softwareUpdateDownloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let preparedUpdate = try await service.downloadAndPrepare(update)
                guard !Task.isCancelled else { return }
                softwareUpdateStatus = .readyToInstall(update)
                preparedSoftwareUpdate = preparedUpdate
                preparedSoftwareUpdatePrompt = preparedUpdate
            } catch {
                guard !Task.isCancelled else { return }
                softwareUpdateStatus = .failed(error.localizedDescription)
                actionError = ViewerActionError(title: "Update konnte nicht vorbereitet werden", message: error.localizedDescription)
            }
            softwareUpdateDownloadTask = nil
        }
    }

    func dismissPreparedSoftwareUpdatePrompt() {
        preparedSoftwareUpdatePrompt = nil
    }

    func installPreparedSoftwareUpdate(_ preparedUpdate: PreparedSoftwareUpdate) {
        do {
            try SoftwareUpdateInstaller.scheduleInstallation(of: preparedUpdate)
            NSApp.terminate(nil)
        } catch {
            actionError = ViewerActionError(
                title: "Update konnte nicht installiert werden",
                message: "Die laufende App kann an diesem Ort nicht ersetzt werden. Lege RAW Viewer bitte zuerst in den Programme-Ordner und versuche es erneut.\n\n\(error.localizedDescription)"
            )
        }
    }

    func clearThumbnailCache() async {
        cancelThumbnailPreparation(reset: true)
        await thumbnailService.clear()
        await updateCacheStatistics()
        prepareThumbnailsForCurrentGrid(force: true)
    }

    func rebuildIndex() async {
        guard isCacheConfigured else { return }
        do {
            try await catalog.removeAllFiles()
            cancelThumbnailPreparation(reset: true)
            photos = []
            refresh()
            await updateCacheStatistics()
        } catch {
            actionError = ViewerActionError(title: "Index konnte nicht erneuert werden", message: error.localizedDescription)
        }
    }

    func updateCacheStatistics() async {
        guard isCacheConfigured else {
            cacheStats = .empty
            return
        }
        let thumbnailStats = await thumbnailService.statistics()
        let indexedCount = (try? await catalog.indexedFileCount()) ?? 0
        let analyzedCount = (try? await catalog.analysisCount()) ?? 0
        let storedPersonDataCount = (try? await catalog.personDataCount()) ?? 0
        cacheStats = ViewerCacheStats(
            indexedFileCount: indexedCount,
            analyzedPhotoCount: analyzedCount,
            storedPersonDataCount: storedPersonDataCount,
            thumbnailFileCount: thumbnailStats.fileCount,
            thumbnailByteCount: thumbnailStats.byteCount
        )
    }

    var selectedPhotoID: PhotoAsset.ID? { photoSelection.primaryID }

    var selectedPhotoIDs: Set<PhotoAsset.ID> { photoSelection.ids }

    var selectedPhotoCount: Int { photoSelection.count }

    var selectedPhotos: [PhotoAsset] {
        photos.filter { photoSelection.ids.contains($0.id) }
    }

    var selectedPhoto: PhotoAsset? {
        guard let selectedPhotoID else { return nil }
        return photos.first { $0.id == selectedPhotoID }
    }

    func isPhotoSelected(_ photo: PhotoAsset) -> Bool {
        selectedPhotoIDs.contains(photo.id)
    }

    func selectPhoto(_ photo: PhotoAsset, modifiers: PhotoSelectionModifiers = []) {
        photoSelection.select(photo.id, orderedIDs: visiblePhotos.map(\.id), modifiers: modifiers)
    }

    func selectAllVisiblePhotos() {
        photoSelection.selectAll(visiblePhotos.map(\.id))
    }

    func clearPhotoSelection() {
        photoSelection.clear()
    }

    func handleEscapeKey() {
        switch viewMode.escapeKeyAction {
        case .clearSelection:
            clearPhotoSelection()
        case .closePhoto:
            closePhoto()
        }
    }

    func photosForAction(containing photo: PhotoAsset) -> [PhotoAsset] {
        guard selectedPhotoIDs.contains(photo.id), !selectedPhotos.isEmpty else { return [photo] }
        return selectedPhotos
    }

    func actionPhotoCount(containing photo: PhotoAsset) -> Int {
        photosForAction(containing: photo).count
    }

    var selectedFolderName: String {
        selectedFolderURL?.lastPathComponent ?? "Ordner"
    }

    var photosInSelectedFolderScope: [PhotoAsset] {
        guard selectedFolderURL != nil else { return [] }
        return photos
    }

    var missingAnalysisCountInSelectedFolder: Int {
        photosInSelectedFolderScope.filter { analysesByPhotoID[$0.id] == nil }.count
    }

    var xmpEligibleAnalysisCountInSelectedFolder: Int {
        photosInSelectedFolderScope.filter {
            xmpSidecarService.sidecarURL(for: $0) != nil
                && (!effectiveKeywords(for: $0).isEmpty || !previouslyExportedPersonKeywords(for: $0.id).isEmpty)
        }.count
    }

    var pendingXMPExportCountInSelectedFolder: Int {
        photosInSelectedFolderScope.filter { asset in
            let keywordsJSON = effectiveKeywordsJSON(for: asset)
            guard let expectedURL = xmpSidecarService.sidecarURL(for: asset),
                  keywordsJSON != "[]" || !previouslyExportedPersonKeywords(for: asset.id).isEmpty else { return false }
            guard let record = xmpExportsByPhotoID[asset.id],
                  record.matches(keywordsJSON: keywordsJSON),
                  record.sidecarPath == expectedURL.standardizedFileURL.path else { return true }
            return false
        }.count
    }

    var visiblePhotos: [PhotoAsset] {
        let terms = searchText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return photos }
        return photos.filter { photo in
            let analysis = analysesByPhotoID[photo.id]
            let searchable = ([photo.filename, photo.typeLabel, analysis?.description ?? ""]
                + effectiveKeywords(for: photo))
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return terms.allSatisfy(searchable.contains)
        }
    }

    func effectiveKeywords(for asset: PhotoAsset) -> [String] {
        Self.uniqueKeywords(analysesByPhotoID[asset.id]?.keywords ?? [])
    }

    func effectiveKeywordsJSON(for asset: PhotoAsset) -> String {
        guard let data = try? JSONEncoder().encode(effectiveKeywords(for: asset)),
              let value = String(data: data, encoding: .utf8) else { return "[]" }
        return value
    }

    var selectedSource: PhotoSource? {
        guard let selectedFolderURL else { return nil }
        return sources
            .filter { selectedFolderURL.isDescendant(of: $0.url) }
            .max { $0.url.path.count < $1.url.path.count }
    }

    var canShowPrevious: Bool {
        guard let selectedPhotoID, let index = visiblePhotos.firstIndex(where: { $0.id == selectedPhotoID }) else { return false }
        return index > 0
    }

    var canShowNext: Bool {
        guard let selectedPhotoID, let index = visiblePhotos.firstIndex(where: { $0.id == selectedPhotoID }) else { return false }
        return index + 1 < visiblePhotos.count
    }

    func chooseAndAddSources() {
        guard !isCheckingSourceSize else { return }
        checkAndAddSources(FolderPanelService.chooseFolders())
    }

    func checkAndAddSources(_ urls: [URL]) {
        let newURLs = urls
            .map(\.standardizedFileURL)
            .filter { url in !sources.contains(where: { $0.id == url.path }) }
        guard !newURLs.isEmpty else { return }

        sourceSizeCheckTask?.cancel()
        isCheckingSourceSize = true
        let checker = folderSizeChecker
        sourceSizeCheckTask = Task { @MainActor [weak self] in
            do {
                var oversizedFolders: [URL] = []
                for url in newURLs {
                    let result = try await checker.check(folderURL: url)
                    if result.exceedsLimit {
                        oversizedFolders.append(url)
                    }
                }
                guard let self else { return }
                isCheckingSourceSize = false
                if oversizedFolders.isEmpty {
                    commitSources(newURLs)
                } else {
                    largePhotoSourceWarning = LargePhotoSourceWarning(
                        urls: newURLs,
                        oversizedFolders: oversizedFolders
                    )
                }
            } catch is CancellationError {
                self?.isCheckingSourceSize = false
            } catch {
                guard let self else { return }
                isCheckingSourceSize = false
                actionError = ViewerActionError(
                    title: "Fotoanzahl konnte nicht geprüft werden",
                    message: error.localizedDescription
                )
            }
        }
    }

    func confirmAddingLargePhotoSources() {
        guard let warning = largePhotoSourceWarning else { return }
        largePhotoSourceWarning = nil
        commitSources(warning.urls)
    }

    func cancelAddingLargePhotoSources() {
        largePhotoSourceWarning = nil
    }

    private func commitSources(_ urls: [URL]) {
        for url in urls {
            let source = bookmarkStore.makeSource(url: url)
            guard !sources.contains(where: { $0.id == source.id }) else { continue }
            sources.append(source)
        }
        sources.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        bookmarkStore.saveSources(sources)
        if isCacheConfigured, let first = urls.first {
            selectFolder(first.standardizedFileURL)
        }
    }

    func removeSelectedSource() {
        guard let source = selectedSource else { return }
        analysisTask?.cancel()
        xmpExportTask?.cancel()
        source.url.stopAccessingSecurityScopedResource()
        folderLocationStore.clearFolder(ifInside: source.url)
        sources.removeAll { $0.id == source.id }
        bookmarkStore.saveSources(sources)
        folderChildren = folderChildren.filter { key, _ in
            !URL(fileURLWithPath: key).isDescendant(of: source.url)
        }
        selectedFolderURL = nil
        photoSelection.clear()
        photos = []
        analysesByPhotoID = [:]
        xmpExportsByPhotoID = [:]
        rotationEditsByPhotoID = [:]
        viewMode = .grid
        scanTask?.cancel()
        cancelThumbnailPreparation(reset: true)
        watcher?.stop()
        watchedPath = nil
    }

    func selectFolder(_ url: URL) {
        guard isCacheConfigured else { return }
        analysisTask?.cancel()
        xmpExportTask?.cancel()
        guard FileManager.default.fileExists(atPath: url.path) else {
            selectedFolderURL = url
            photoSelection.clear()
            photos = []
            scanError = "Der Ordner ist derzeit nicht erreichbar."
            return
        }
        selectedFolderURL = url.standardizedFileURL
        folderLocationStore.saveFolder(url)
        photoSelection.clear()
        viewMode = .grid
        cancelThumbnailPreparation(reset: true)
        configureWatcher(for: url)
        refresh()
    }

    func refresh() {
        guard isCacheConfigured, let folderURL = selectedFolderURL else { return }
        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        isScanning = true
        scanError = nil
        let scanner = self.scanner
        let catalog = self.catalog

        scanTask = Task { @MainActor [weak self] in
            do {
                let cachedFiles = try await catalog.files(in: folderURL)
                try Task.checkCancellation()
                let cachedAssets = try await scanner.assets(from: cachedFiles)
                try Task.checkCancellation()
                guard let self, scanGeneration == generation,
                      selectedFolderURL?.standardizedFileURL == folderURL.standardizedFileURL else { return }
                photos = sortOrder.sort(cachedAssets)
                await loadAnalyses(for: photos, in: folderURL)
                prepareThumbnailsForCurrentGrid(force: true)

                let result = try await scanner.scan(folderURL: folderURL, cachedFiles: cachedFiles)
                try Task.checkCancellation()
                try await catalog.replaceFiles(in: folderURL, with: result.indexedFiles)
                try Task.checkCancellation()
                guard scanGeneration == generation,
                      selectedFolderURL?.standardizedFileURL == folderURL.standardizedFileURL else { return }
                photos = sortOrder.sort(result.assets)
                await loadAnalyses(for: photos, in: folderURL)
                prepareThumbnailsForCurrentGrid(force: true)
                isScanning = false
                photoSelection.prune(to: photos.map(\.id))
                if selectedPhotoID == nil, viewMode == .photo {
                    viewMode = .grid
                }
                await updateCacheStatistics()
            } catch is CancellationError {
                guard let self, scanGeneration == generation else { return }
                self.isScanning = false
            } catch {
                guard let self, scanGeneration == generation else { return }
                if photos.isEmpty { self.photos = [] }
                self.isScanning = false
                self.scanError = error.localizedDescription
            }
        }
    }

    func setSortOrder(_ newValue: PhotoSortOrder) {
        sortOrder = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: PreferenceKeys.sortOrder)
        photos = newValue.sort(photos)
    }

    func loadChildren(of url: URL, force: Bool = false) {
        let key = url.standardizedFileURL.path
        if !force, folderChildren[key] != nil { return }
        folderTasks[key]?.cancel()
        loadingFolders.insert(key)

        folderTasks[key] = Task { @MainActor [weak self] in
            let children = await Task.detached(priority: .utility) {
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .isPackageKey, .isSymbolicLinkKey]
                guard let urls = try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                ) else { return [FolderItem]() }
                return urls.compactMap { child -> FolderItem? in
                    let values = try? child.resourceValues(forKeys: keys)
                    guard values?.isDirectory == true,
                          values?.isHidden != true,
                          values?.isPackage != true,
                          values?.isSymbolicLink != true else { return nil }
                    return FolderItem(url: child.standardizedFileURL)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }.value
            guard let self, !Task.isCancelled else { return }
            folderChildren[key] = children
            loadingFolders.remove(key)
            folderTasks[key] = nil
        }
    }

    func children(of url: URL) -> [FolderItem]? {
        folderChildren[url.standardizedFileURL.path]
    }

    func openPhoto(_ photo: PhotoAsset) {
        if !selectedPhotoIDs.contains(photo.id) {
            photoSelection.replace(with: photo.id)
        }
        viewMode = .photo
        viewerFitsWindow = true
        viewerZoom = 1
    }

    func revealInFinder(_ photo: PhotoAsset) {
        let actionPhotos = photosForAction(containing: photo)
        if !selectedPhotoIDs.contains(photo.id) {
            photoSelection.replace(with: photo.id)
        }
        NSWorkspace.shared.activateFileViewerSelecting(actionPhotos.map(\.primaryURL))
    }

    func rotation(for photo: PhotoAsset) -> PhotoRotation {
        rotationEditsByPhotoID[photo.id]?.rotation ?? .none
    }

    func rotationEdit(for photo: PhotoAsset) -> PhotoRotationEdit? {
        rotationEditsByPhotoID[photo.id]
    }

    var canResetSelectedRotation: Bool {
        selectedPhotos.contains { rotationEditsByPhotoID[$0.id] != nil }
    }

    var selectedPhotoNeedsXMPSync: Bool {
        guard let selectedPhoto else { return false }
        return rotationEditsByPhotoID[selectedPhoto.id]?.isXMPSyncPending == true
    }

    func rotateSelectedPhotoLeft() {
        rotate(selectedPhotos, direction: .left)
    }

    func rotateSelectedPhotoRight() {
        rotate(selectedPhotos, direction: .right)
    }

    func rotate(_ photo: PhotoAsset, direction: PhotoRotation) {
        let actionPhotos = photosForAction(containing: photo)
        if !selectedPhotoIDs.contains(photo.id) {
            photoSelection.replace(with: photo.id)
        }
        rotate(actionPhotos, direction: direction)
    }

    func resetRotation(_ photo: PhotoAsset) {
        let actionPhotos = photosForAction(containing: photo)
        if !selectedPhotoIDs.contains(photo.id) {
            photoSelection.replace(with: photo.id)
        }
        resetRotation(actionPhotos)
    }

    func resetSelectedRotation() {
        resetRotation(selectedPhotos)
    }

    func retryXMPSync(_ photo: PhotoAsset) {
        guard var edit = rotationEditsByPhotoID[photo.id], edit.isXMPSyncPending else { return }
        edit.xmpSyncError = nil
        edit.updatedAt = Date()
        rotationEditsByPhotoID[photo.id] = edit
        queueRotationPersistence(for: photo)
    }

    func export(_ photo: PhotoAsset, as format: PhotoExportFormat) {
        let actionPhotos = photosForAction(containing: photo)
        if !selectedPhotoIDs.contains(photo.id) {
            photoSelection.replace(with: photo.id)
        }
        beginExport(actionPhotos, as: format)
    }

    func exportSelectedPhotos(as format: PhotoExportFormat) {
        beginExport(selectedPhotos, as: format)
    }

    private func rotate(_ actionPhotos: [PhotoAsset], direction: PhotoRotation) {
        guard !actionPhotos.isEmpty else { return }
        for photo in actionPhotos {
            let current = rotation(for: photo)
            let next = direction == .left ? current.rotatedLeft() : current.rotatedRight()
            updateRotationEdit(for: photo, rotation: next)
        }
    }

    private func resetRotation(_ actionPhotos: [PhotoAsset]) {
        for photo in actionPhotos where rotationEditsByPhotoID[photo.id] != nil {
            updateRotationEdit(for: photo, rotation: .none)
        }
    }

    private func beginExport(_ actionPhotos: [PhotoAsset], as format: PhotoExportFormat) {
        guard !isExporting, !actionPhotos.isEmpty else { return }
        isExporting = true
        photoExportProgress = PhotoExportProgress(
            phase: .exporting,
            total: actionPhotos.count,
            completed: 0,
            failed: 0
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isExporting = false }
            do {
                if actionPhotos.count == 1, let photo = actionPhotos.first {
                    let didExport = try await exportService.chooseDestinationAndExport(
                        photo,
                        format: format,
                        rotation: rotation(for: photo)
                    )
                    photoExportProgress = didExport
                        ? PhotoExportProgress(phase: .complete, total: 1, completed: 1, failed: 0)
                        : .idle
                    return
                }

                let items = actionPhotos.map {
                    PhotoExportItem(asset: $0, rotation: rotation(for: $0))
                }
                guard let result = try await exportService.chooseDirectoryAndExport(
                    items,
                    format: format,
                    progress: { [weak self] completed, failed in
                        self?.photoExportProgress = PhotoExportProgress(
                            phase: .exporting,
                            total: items.count,
                            completed: completed,
                            failed: failed
                        )
                    }
                ) else {
                    photoExportProgress = .idle
                    return
                }
                photoExportProgress = PhotoExportProgress(
                    phase: .complete,
                    total: items.count,
                    completed: result.exportedCount,
                    failed: result.failures.count
                )
                if !result.failures.isEmpty {
                    let details = result.failures.prefix(5)
                        .map { "\($0.filename): \($0.message)" }
                        .joined(separator: "\n")
                    let remainder = result.failures.count > 5
                        ? "\n… und \(result.failures.count - 5) weitere"
                        : ""
                    actionError = ViewerActionError(
                        title: "\(result.exportedCount) von \(items.count) Fotos exportiert",
                        message: details + remainder
                    )
                }
            } catch is CancellationError {
                photoExportProgress = .idle
                return
            } catch {
                photoExportProgress = PhotoExportProgress(
                    phase: .complete,
                    total: actionPhotos.count,
                    completed: 0,
                    failed: actionPhotos.count
                )
                actionError = ViewerActionError(title: "Export fehlgeschlagen", message: error.localizedDescription)
            }
        }
    }

    func closePhoto() {
        viewMode = .grid
        viewerFitsWindow = true
        viewerZoom = 1
    }

    func showPreviousPhoto() {
        guard let selectedPhotoID,
              let index = visiblePhotos.firstIndex(where: { $0.id == selectedPhotoID }),
              index > 0 else { return }
        photoSelection.replace(with: visiblePhotos[index - 1].id)
        viewerFitsWindow = true
        viewerZoom = 1
    }

    func showNextPhoto() {
        guard let selectedPhotoID,
              let index = visiblePhotos.firstIndex(where: { $0.id == selectedPhotoID }),
              index + 1 < visiblePhotos.count else { return }
        photoSelection.replace(with: visiblePhotos[index + 1].id)
        viewerFitsWindow = true
        viewerZoom = 1
    }

    func zoomIn() {
        viewerFitsWindow = false
        viewerZoom = min(8, max(0.25, viewerZoom * 1.25))
    }

    func zoomOut() {
        viewerFitsWindow = false
        viewerZoom = max(0.25, min(8, viewerZoom / 1.25))
    }

    func fitImage() {
        viewerFitsWindow = true
    }

    func actualSize() {
        viewerFitsWindow = false
        viewerZoom = 1
    }

    func renderImage(url: URL, isRAW: Bool, maxPixelSize: Int) async throws -> RenderedImage {
        try await fullImageService.render(url: url, isRAW: isRAW, maxPixelSize: maxPixelSize)
    }

    func thumbnailPreview(for asset: PhotoAsset) async -> RenderedImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = await thumbnailService.thumbnail(
            for: asset,
            requestedPixelSize: 512,
            scale: scale
        ), let pixelSize = ThumbnailService.pixelSize(of: image) else { return nil }
        return RenderedImage(image: image, pixelSize: pixelSize)
    }

    func prepareThumbnails(tileSize: Double, force: Bool = false) {
        guard isCacheConfigured, let folderURL = selectedFolderURL, !photos.isEmpty else {
            cancelThumbnailPreparation(reset: true)
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let requestedPixelSize = max(256, Int(tileSize * scale))
        let bucket = ThumbnailService.pixelBucket(for: requestedPixelSize)
        let key = "\(folderURL.standardizedFileURL.path)|\(bucket)"
        if !force, preparedThumbnailKey == key { return }

        thumbnailPreparationTask?.cancel()
        preparedThumbnailKey = key
        let generation = UUID()
        thumbnailPreparationGeneration = generation
        let assets = photos
        let service = thumbnailService
        thumbnailPreparation.update(ThumbnailPreparationProgress(
            phase: .checking,
            total: assets.count,
            checked: 0,
            ready: 0,
            failed: 0
        ))

        thumbnailPreparationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                let cachedIDs = await service.cachedAssetIDs(for: assets, requestedPixelSize: requestedPixelSize)
                try Task.checkCancellation()
                guard let self, thumbnailPreparationGeneration == generation else { return }

                let pending = assets.filter { !cachedIDs.contains($0.id) }
                var ready = cachedIDs.count
                var failed = 0
                thumbnailPreparation.update(ThumbnailPreparationProgress(
                    phase: pending.isEmpty ? .complete : .rendering,
                    total: assets.count,
                    checked: assets.count,
                    ready: ready,
                    failed: failed
                ))
                guard !pending.isEmpty else {
                    thumbnailPreparationTask = nil
                    await updateCacheStatistics()
                    return
                }

                let updateStride = max(1, pending.count / 100)
                var finishedSinceUpdate = 0
                await withTaskGroup(of: Bool.self) { group in
                    var iterator = pending.makeIterator()
                    for _ in 0..<min(2, pending.count) {
                        if let asset = iterator.next() {
                            group.addTask(priority: .utility) {
                                await service.thumbnail(
                                    for: asset,
                                    requestedPixelSize: requestedPixelSize,
                                    scale: scale
                                ) != nil
                            }
                        }
                    }

                    while let succeeded = await group.next() {
                        if Task.isCancelled {
                            group.cancelAll()
                            return
                        }
                        if succeeded { ready += 1 } else { failed += 1 }
                        finishedSinceUpdate += 1
                        if finishedSinceUpdate >= updateStride || ready + failed == assets.count {
                            finishedSinceUpdate = 0
                            thumbnailPreparation.update(ThumbnailPreparationProgress(
                                phase: .rendering,
                                total: assets.count,
                                checked: assets.count,
                                ready: ready,
                                failed: failed
                            ))
                        }
                        if let asset = iterator.next() {
                            group.addTask(priority: .utility) {
                                await service.thumbnail(
                                    for: asset,
                                    requestedPixelSize: requestedPixelSize,
                                    scale: scale
                                ) != nil
                            }
                        }
                    }
                }

                try Task.checkCancellation()
                guard thumbnailPreparationGeneration == generation else { return }
                thumbnailPreparation.update(ThumbnailPreparationProgress(
                    phase: .complete,
                    total: assets.count,
                    checked: assets.count,
                    ready: ready,
                    failed: failed
                ))
                thumbnailPreparationTask = nil
                await updateCacheStatistics()
            } catch is CancellationError {
                return
            } catch {
                guard let self, thumbnailPreparationGeneration == generation else { return }
                thumbnailPreparation.update(ThumbnailPreparationProgress(
                    phase: .complete,
                    total: assets.count,
                    checked: assets.count,
                    ready: 0,
                    failed: assets.count
                ))
                thumbnailPreparationTask = nil
            }
        }
    }

    private func prepareThumbnailsForCurrentGrid(force: Bool) {
        let savedTileSize = UserDefaults.standard.object(forKey: PreferenceKeys.gridTileSize) != nil
            ? UserDefaults.standard.double(forKey: PreferenceKeys.gridTileSize)
            : 180
        prepareThumbnails(tileSize: savedTileSize, force: force)
    }

    private func cancelThumbnailPreparation(reset: Bool) {
        thumbnailPreparationTask?.cancel()
        thumbnailPreparationTask = nil
        thumbnailPreparationGeneration = UUID()
        if reset {
            preparedThumbnailKey = nil
            thumbnailPreparation.update(.idle)
        }
    }

    private func configureWatcher(for url: URL) {
        let path = url.standardizedFileURL.path
        guard watchedPath != path else { return }
        watcher?.stop()
        watchedPath = path
        let newWatcher = FolderWatcher { [weak self] changedPaths in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let relevantPaths = changedPaths.filter {
                    URL(fileURLWithPath: $0).pathExtension.lowercased() != "xmp"
                }
                guard !relevantPaths.isEmpty else { return }
                folderChildren.removeAll()
                applyFileSystemChanges(relevantPaths)
            }
        }
        watcher = newWatcher
        newWatcher.start(path: path)
    }

    private func applyFileSystemChanges(_ changedPaths: [String]) {
        guard isCacheConfigured, let folderURL = selectedFolderURL else { return }
        guard !changedPaths.isEmpty else {
            refresh()
            return
        }

        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        isScanning = true
        scanError = nil
        let scanner = self.scanner
        let catalog = self.catalog

        scanTask = Task { @MainActor [weak self] in
            do {
                let cachedFiles = try await catalog.files(in: folderURL)
                let cachedByPath = Dictionary(uniqueKeysWithValues: cachedFiles.map { ($0.path, $0) })
                var deletedPaths: [String] = []
                var changedFileURLs: [URL] = []
                var changedDirectoryURLs: [URL] = []

                for path in Set(changedPaths) {
                    try Task.checkCancellation()
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    guard url.isDescendant(of: folderURL) else { continue }
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                        if isDirectory.boolValue {
                            changedDirectoryURLs.append(url)
                        } else if PhotoFileKind.classify(url) != nil {
                            changedFileURLs.append(url)
                        }
                    } else {
                        deletedPaths.append(url.path)
                    }
                }

                if !changedFileURLs.isEmpty || !deletedPaths.isEmpty || changedDirectoryURLs.count > 1 {
                    changedDirectoryURLs.removeAll { $0.standardizedFileURL == folderURL.standardizedFileURL }
                }
                changedDirectoryURLs = Self.outermostDirectories(changedDirectoryURLs)

                try await catalog.removePathsAndDescendants(deletedPaths)
                for directory in changedDirectoryURLs {
                    let cachedInDirectory = cachedFiles.filter { $0.url.isDescendant(of: directory) }
                    let result = try await scanner.scan(folderURL: directory, cachedFiles: cachedInDirectory)
                    try await catalog.replaceFiles(in: directory, with: result.indexedFiles)
                }

                var changedFiles: [IndexedPhotoFile] = []
                for url in changedFileURLs {
                    if let file = try await scanner.indexedFile(at: url, cachedFile: cachedByPath[url.path]) {
                        changedFiles.append(file)
                    }
                }
                try await catalog.upsertFiles(changedFiles)

                let updatedFiles = try await catalog.files(in: folderURL)
                let updatedAssets = try await scanner.assets(from: updatedFiles)
                try Task.checkCancellation()
                guard let self, scanGeneration == generation,
                      selectedFolderURL?.standardizedFileURL == folderURL.standardizedFileURL else { return }
                photos = sortOrder.sort(updatedAssets)
                await loadAnalyses(for: photos, in: folderURL)
                prepareThumbnailsForCurrentGrid(force: true)
                isScanning = false
                photoSelection.prune(to: photos.map(\.id))
                if selectedPhotoID == nil, viewMode == .photo {
                    viewMode = .grid
                }
                await updateCacheStatistics()
            } catch is CancellationError {
                guard let self, scanGeneration == generation else { return }
                self.isScanning = false
            } catch {
                guard let self, scanGeneration == generation else { return }
                self.isScanning = false
                self.scanError = error.localizedDescription
            }
        }
    }

    private static func outermostDirectories(_ urls: [URL]) -> [URL] {
        let sorted = Set(urls.map { $0.standardizedFileURL }).sorted { $0.path.count < $1.path.count }
        var result: [URL] = []
        for url in sorted where !result.contains(where: { url.isDescendant(of: $0) }) {
            result.append(url)
        }
        return result
    }

    private func activateCache(at url: URL, persist: Bool) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "Der gewählte Cache-Ordner ist nicht erreichbar."
            ])
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "Im gewählten Cache-Ordner kann nicht geschrieben werden."
            ])
        }

        scanTask?.cancel()
        watcher?.stop()
        watchedPath = nil
        try await catalog.configure(cacheDirectory: url)
        let hasSavedLimit = UserDefaults.standard.object(forKey: PreferenceKeys.cacheSizeLimitGB) != nil
        let limit = hasSavedLimit ? UserDefaults.standard.integer(forKey: PreferenceKeys.cacheSizeLimitGB) : 20
        try await thumbnailService.configure(cacheDirectory: url, sizeLimitGB: limit)
        if persist { cacheLocationStore.save(url) }
        cacheDirectoryURL = url.standardizedFileURL
        isCacheConfigured = true
        cacheSetupError = nil
        await updateCacheStatistics()

        if let folder = selectedFolderURL
            ?? folderLocationStore.loadFolder(in: sources)
            ?? sources.first(where: \.isAvailable)?.url {
            selectFolder(folder)
        }
    }

    func checkLMStudioAtLaunch() async {
        guard !didCheckLMStudio else { return }
        didCheckLMStudio = true
        await refreshLMStudioStatus(startLocalIfNeeded: true)
    }

    func lmStudioConfigurationDidChange() {
        guard !isLMStudioBusy else { return }
        lmStudioStatus = .unknown
    }

    func refreshLMStudioStatus(startLocalIfNeeded: Bool = false) async {
        guard !isLMStudioBusy else { return }
        isLMStudioBusy = true
        lmStudioStatus = .checking
        defer { isLMStudioBusy = false }
        let configuration = LMStudioConfiguration.current()
        do {
            lmStudioStatus = try await lmStudioService.runtimeStatus(
                configuration: configuration,
                startLocalIfNeeded: startLocalIfNeeded
            )
        } catch {
            lmStudioStatus = LMStudioRuntimeStatus(
                connection: .unavailable,
                models: [],
                selectedModelKey: nil,
                loadedInstanceID: nil,
                message: error.localizedDescription
            )
        }
    }

    func loadConfiguredLMStudioModel() async {
        guard !isLMStudioBusy else { return }
        isLMStudioBusy = true
        lmStudioStatus = .checking
        defer { isLMStudioBusy = false }
        do {
            _ = try await lmStudioService.prepareModel(
                configuration: .current(),
                reloadIfAlreadyLoaded: true
            )
            lmStudioStatus = try await lmStudioService.runtimeStatus(configuration: .current())
        } catch {
            lmStudioStatus = LMStudioRuntimeStatus(
                connection: .unavailable,
                models: [],
                selectedModelKey: nil,
                loadedInstanceID: nil,
                message: error.localizedDescription
            )
        }
    }

    func unloadConfiguredLMStudioModel() async {
        guard !isLMStudioBusy else { return }
        isLMStudioBusy = true
        defer { isLMStudioBusy = false }
        do {
            try await lmStudioService.unloadConfiguredModel(configuration: .current())
            lmStudioStatus = try await lmStudioService.runtimeStatus(configuration: .current())
        } catch {
            lmStudioStatus = LMStudioRuntimeStatus(
                connection: .unavailable,
                models: lmStudioStatus.models,
                selectedModelKey: lmStudioStatus.selectedModelKey,
                loadedInstanceID: lmStudioStatus.loadedInstanceID,
                message: error.localizedDescription
            )
        }
    }

    func analyzeSelectedPhoto() {
        guard let selectedPhoto else { return }
        analyzePhotos([selectedPhoto])
    }

    func analyzeMissingPhotosInSelectedFolder() {
        let pending = photosInSelectedFolderScope.filter { analysesByPhotoID[$0.id] == nil }
        guard !pending.isEmpty else { return }
        analyzePhotos(pending)
    }

    func regenerateKeywordsInSelectedFolder() {
        let assets = photosInSelectedFolderScope
        guard !assets.isEmpty else { return }
        analyzePhotos(assets)
    }

    func cancelPhotoAnalysis() {
        analysisTask?.cancel()
    }

    private func analyzePhotos(_ assets: [PhotoAsset]) {
        guard analysisTask == nil, xmpExportTask == nil, !assets.isEmpty else { return }
        let configuration = LMStudioConfiguration.current()
        let service = lmStudioService
        let catalog = self.catalog
        let fullImageService = self.fullImageService
        analysisProgress = PhotoAnalysisProgress(
            isRunning: true,
            total: assets.count,
            completed: 0,
            failed: 0,
            currentFilename: nil
        )

        analysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var handle: LMStudioModelHandle?
            var completed = 0
            var failed = 0
            var firstFailure: Error?
            var wasCancelled = false
            var successfullyAnalyzedPhotoIDs: Set<PhotoAsset.ID> = []

            do {
                handle = try await service.prepareModel(configuration: configuration)
                if let handle {
                    for asset in assets {
                        try Task.checkCancellation()
                        analyzingPhotoID = asset.id
                        analysisProgress = PhotoAnalysisProgress(
                            isRunning: true,
                            total: assets.count,
                            completed: completed,
                            failed: failed,
                            currentFilename: asset.filename
                        )
                        do {
                            let jpeg = try await PhotoAnalysisImageEncoder.jpegData(
                                for: asset,
                                fullImageService: fullImageService
                            )
                            try Task.checkCancellation()
                            let result = try await service.analyzeJPEG(
                                jpeg,
                                filename: asset.filename,
                                handle: handle,
                                configuration: configuration
                            )
                            try Task.checkCancellation()
                            let analysis = PhotoAnalysis(
                                photoID: asset.id,
                                sourcePath: asset.primaryURL.standardizedFileURL.path,
                                sourceModificationDate: asset.modificationDate,
                                modelIdentifier: handle.modelKey,
                                keywords: result.keywords,
                                description: result.description,
                                analyzedAt: Date()
                            )
                            try await catalog.saveAnalysis(analysis)
                            analysesByPhotoID[asset.id] = analysis
                            xmpExportsByPhotoID.removeValue(forKey: asset.id)
                            successfullyAnalyzedPhotoIDs.insert(asset.id)
                            completed += 1
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            failed += 1
                            firstFailure = firstFailure ?? error
                        }
                    }
                }
            } catch is CancellationError {
                // The progress summary below preserves already completed analyses.
                wasCancelled = true
            } catch {
                firstFailure = error
                failed = max(failed, assets.count - completed)
            }

            if let handle, handle.loadedByApp, configuration.unloadAfterAnalysis {
                try? await service.unload(handle, configuration: configuration)
            }
            analyzingPhotoID = nil
            analysisProgress = PhotoAnalysisProgress(
                isRunning: false,
                total: assets.count,
                completed: completed,
                failed: failed,
                currentFilename: nil
            )
            analysisTask = nil
            await updateCacheStatistics()
            await refreshLMStudioStatus()

            if !wasCancelled, failed == 0 {
                suggestXMPExport(for: successfullyAnalyzedPhotoIDs)
            }

            if failed > 0, let firstFailure {
                actionError = ViewerActionError(
                    title: "Fotoanalyse nicht vollständig",
                    message: "\(failed) von \(assets.count) Fotos konnten nicht analysiert werden.\n\n\(firstFailure.localizedDescription)"
                )
            }
        }
    }

    func confirmXMPExportSuggestion() {
        guard let suggestion = xmpExportSuggestion else { return }
        xmpExportSuggestion = nil
        exportPendingXMPInSelectedFolder(onlyPhotoIDs: suggestion.photoIDs)
    }

    func dismissXMPExportSuggestion() {
        xmpExportSuggestion = nil
    }

    func exportPendingXMPInSelectedFolder(onlyPhotoIDs: Set<PhotoAsset.ID>? = nil) {
        guard xmpExportTask == nil, analysisTask == nil else { return }
        let exportScope = onlyPhotoIDs == nil ? photosInSelectedFolderScope : photos
        let candidates = exportScope.compactMap { asset -> (PhotoAsset, [String], [String], String)? in
            guard onlyPhotoIDs?.contains(asset.id) ?? true else { return nil }
            let keywords = effectiveKeywords(for: asset)
            let previousPersonKeywords = previouslyExportedPersonKeywords(for: asset.id)
            let keywordsJSON = effectiveKeywordsJSON(for: asset)
            guard (!keywords.isEmpty || !previousPersonKeywords.isEmpty),
                  let expectedURL = xmpSidecarService.sidecarURL(for: asset) else { return nil }
            if let record = xmpExportsByPhotoID[asset.id],
               record.matches(keywordsJSON: keywordsJSON),
               record.sidecarPath == expectedURL.standardizedFileURL.path,
               FileManager.default.fileExists(atPath: expectedURL.path) {
                return nil
            }
            return (asset, keywords, previousPersonKeywords, keywordsJSON)
        }
        guard !candidates.isEmpty else { return }

        let service = xmpSidecarService
        let catalog = self.catalog
        xmpExportProgress = XMPExportProgress(
            isRunning: true,
            total: candidates.count,
            completed: 0,
            failed: 0,
            currentFilename: nil
        )

        xmpExportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var completed = 0
            var failed = 0
            var firstFailure: Error?

            for (asset, keywords, previousPersonKeywords, keywordsJSON) in candidates {
                do {
                    try Task.checkCancellation()
                    xmpExportProgress = XMPExportProgress(
                        isRunning: true,
                        total: candidates.count,
                        completed: completed,
                        failed: failed,
                        currentFilename: asset.filename
                    )
                    let result = try await Task.detached(priority: .utility) {
                        try service.writeKeywords(
                            keywords,
                            replacingPersonKeywords: previousPersonKeywords,
                            for: asset
                        )
                    }.value
                    try Task.checkCancellation()
                    let record = XMPExportRecord(
                        photoID: asset.id,
                        sourcePath: asset.primaryURL.standardizedFileURL.path,
                        keywordsJSON: keywordsJSON,
                        sidecarPath: result.url.standardizedFileURL.path,
                        exportedAt: Date()
                    )
                    try await catalog.saveXMPExport(record)
                    xmpExportsByPhotoID[asset.id] = record
                    completed += 1
                } catch is CancellationError {
                    break
                } catch {
                    failed += 1
                    firstFailure = firstFailure ?? error
                }
            }

            xmpExportProgress = XMPExportProgress(
                isRunning: false,
                total: candidates.count,
                completed: completed,
                failed: failed,
                currentFilename: nil
            )
            xmpExportTask = nil

            if failed > 0, let firstFailure {
                actionError = ViewerActionError(
                    title: "XMP-Export nicht vollständig",
                    message: "\(failed) von \(candidates.count) Sidecars konnten nicht aktualisiert werden.\n\n\(firstFailure.localizedDescription)"
                )
            }
        }
    }

    private func suggestXMPExport(for analyzedPhotoIDs: Set<PhotoAsset.ID>) {
        guard xmpExportSuggestion == nil else { return }
        let eligiblePhotoIDs = Set(photos.compactMap { asset -> PhotoAsset.ID? in
            guard analyzedPhotoIDs.contains(asset.id),
                  xmpSidecarService.sidecarURL(for: asset) != nil,
                  !effectiveKeywords(for: asset).isEmpty || !previouslyExportedPersonKeywords(for: asset.id).isEmpty else { return nil }
            return asset.id
        })
        guard !eligiblePhotoIDs.isEmpty else { return }
        xmpExportSuggestion = XMPExportSuggestion(photoIDs: eligiblePhotoIDs)
    }

    func cancelXMPExport() {
        xmpExportTask?.cancel()
    }

    func deleteAllPersonData() async {
        do {
            try await catalog.deleteAllPersonData()
            await updateCacheStatistics()
        } catch {
            actionError = ViewerActionError(title: "Personendaten konnten nicht gelöscht werden", message: error.localizedDescription)
        }
    }

    private func updateRotationEdit(for photo: PhotoAsset, rotation: PhotoRotation) {
        let supportsXMP = xmpSidecarService.sidecarURL(for: photo) != nil
        var edit = rotationEditsByPhotoID[photo.id] ?? PhotoRotationEdit(
            photoID: photo.id,
            sourcePath: photo.primaryURL.standardizedFileURL.path,
            rotation: .none,
            originalXMPOrientation: nil,
            isOriginalXMPOrientationKnown: !supportsXMP,
            isXMPSyncPending: supportsXMP,
            xmpSyncError: nil,
            updatedAt: Date()
        )
        edit.rotation = rotation
        edit.isXMPSyncPending = supportsXMP
        edit.xmpSyncError = nil
        edit.updatedAt = Date()
        rotationEditsByPhotoID[photo.id] = edit
        queueRotationPersistence(for: photo)
    }

    private func queueRotationPersistence(for photo: PhotoAsset) {
        pendingRotationAssets[photo.id] = photo
        guard rotationPersistenceTask == nil else { return }
        rotationPersistenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !pendingRotationAssets.isEmpty, !Task.isCancelled {
                guard let (photoID, photo) = pendingRotationAssets.first else { break }
                pendingRotationAssets.removeValue(forKey: photoID)
                await persistRotationEdit(for: photo)
            }
            rotationPersistenceTask = nil
            if !pendingRotationAssets.isEmpty {
                queueRotationPersistence(for: pendingRotationAssets.first!.value)
            }
        }
    }

    private func persistRotationEdit(for photo: PhotoAsset) async {
        guard var edit = rotationEditsByPhotoID[photo.id] else { return }
        let editTimestamp = edit.updatedAt
        do {
            try await catalog.saveRotationEdit(edit)
        } catch {
            actionError = ViewerActionError(
                title: "Drehung konnte nicht gespeichert werden",
                message: error.localizedDescription
            )
            return
        }

        guard xmpSidecarService.sidecarURL(for: photo) != nil else {
            guard rotationEditsByPhotoID[photo.id]?.updatedAt == editTimestamp else { return }
            if edit.rotation == .none {
                try? await catalog.deleteRotationEdit(photoID: photo.id)
                rotationEditsByPhotoID.removeValue(forKey: photo.id)
            } else {
                edit.isXMPSyncPending = false
                edit.xmpSyncError = nil
                rotationEditsByPhotoID[photo.id] = edit
                try? await catalog.saveRotationEdit(edit)
            }
            return
        }

        if !edit.isOriginalXMPOrientationKnown {
            do {
                let service = xmpSidecarService
                let originalOrientation = try await Task.detached(priority: .utility) {
                    try service.orientation(for: photo)
                }.value
                edit.originalXMPOrientation = originalOrientation
                edit.isOriginalXMPOrientationKnown = true
                try await catalog.saveRotationEdit(edit)
                if rotationEditsByPhotoID[photo.id]?.updatedAt == editTimestamp {
                    rotationEditsByPhotoID[photo.id] = edit
                }
            } catch {
                await recordXMPSyncFailure(error, edit: edit, timestamp: editTimestamp)
                return
            }
        }

        let desiredOrientation: Int?
        if edit.rotation == .none {
            desiredOrientation = edit.originalXMPOrientation
        } else {
            let sourceOrientation = photo.rawURL.map(ImageMetadataReader.orientation(at:)) ?? 1
            desiredOrientation = edit.rotation.applying(toTIFFOrientation: sourceOrientation)
        }

        do {
            let service = xmpSidecarService
            _ = try await Task.detached(priority: .utility) {
                try service.writeOrientation(desiredOrientation, for: photo)
            }.value
            guard rotationEditsByPhotoID[photo.id]?.updatedAt == editTimestamp else { return }
            if edit.rotation == .none {
                try await catalog.deleteRotationEdit(photoID: photo.id)
                rotationEditsByPhotoID.removeValue(forKey: photo.id)
            } else {
                edit.isXMPSyncPending = false
                edit.xmpSyncError = nil
                rotationEditsByPhotoID[photo.id] = edit
                try await catalog.saveRotationEdit(edit)
            }
        } catch {
            await recordXMPSyncFailure(error, edit: edit, timestamp: editTimestamp)
        }
    }

    private func recordXMPSyncFailure(
        _ error: Error,
        edit: PhotoRotationEdit,
        timestamp: Date
    ) async {
        var failedEdit = edit
        failedEdit.isXMPSyncPending = true
        failedEdit.xmpSyncError = error.localizedDescription
        try? await catalog.saveRotationEdit(failedEdit)
        guard rotationEditsByPhotoID[edit.photoID]?.updatedAt == timestamp else { return }
        rotationEditsByPhotoID[edit.photoID] = failedEdit
        actionError = ViewerActionError(
            title: "Drehung gespeichert, XMP nicht synchronisiert",
            message: "Die Anzeige bleibt korrigiert. Du kannst den XMP-Abgleich im Kontextmenü erneut versuchen.\n\n\(error.localizedDescription)"
        )
    }

    private func loadAnalyses(for assets: [PhotoAsset], in folderURL: URL) async {
        let stored = (try? await catalog.analyses(in: folderURL)) ?? []
        let storedExports = (try? await catalog.xmpExports(in: folderURL)) ?? []
        let storedRotations = (try? await catalog.rotationEdits(in: folderURL)) ?? []
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        analysesByPhotoID = Dictionary(uniqueKeysWithValues: stored.compactMap { analysis in
            guard let asset = assetsByID[analysis.photoID], analysis.matches(asset) else { return nil }
            return (analysis.photoID, analysis)
        })
        xmpExportsByPhotoID = Dictionary(uniqueKeysWithValues: storedExports.compactMap { record in
            guard assetsByID[record.photoID] != nil else { return nil }
            return (record.photoID, record)
        })
        rotationEditsByPhotoID = Dictionary(uniqueKeysWithValues: storedRotations.compactMap { edit in
            guard assetsByID[edit.photoID] != nil else { return nil }
            return (edit.photoID, edit)
        })
    }

    private static func uniqueKeywords(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = keywordComparisonKey(trimmed)
            guard !trimmed.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    private func previouslyExportedPersonKeywords(for photoID: PhotoAsset.ID) -> [String] {
        guard let json = xmpExportsByPhotoID[photoID]?.keywordsJSON,
              let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values.filter { Self.keywordComparisonKey($0).hasPrefix("person: ") }
    }

    private static func keywordComparisonKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    }
}

extension URL {
    func isDescendant(of ancestor: URL) -> Bool {
        let path = standardizedFileURL.path
        let ancestorPath = ancestor.standardizedFileURL.path
        return path == ancestorPath || path.hasPrefix(ancestorPath.hasSuffix("/") ? ancestorPath : ancestorPath + "/")
    }
}
