import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: LibraryStore
    @AppStorage(PreferenceKeys.theme) private var theme = ThemePreference.system.rawValue
    @AppStorage(PreferenceKeys.gridTileSize) private var gridTileSize = 180.0
    @AppStorage(PreferenceKeys.cacheSizeLimitGB) private var cacheSizeLimitGB = 20
    @State private var confirmation: CacheConfirmation?

    var body: some View {
        TabView {
            appearanceSettings
                .tabItem {
                    Label("Darstellung", systemImage: "paintbrush")
                }

            cacheSettings
                .tabItem {
                    Label("Cache", systemImage: "externaldrive")
                }

            LMStudioSettingsView(store: store)
                .tabItem {
                    Label("KI-Analyse", systemImage: "sparkles")
                }

            softwareUpdateSettings
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 620, height: 440)
        .alert(item: $confirmation) { confirmation in
            switch confirmation {
            case .clearThumbnails:
                Alert(
                    title: Text("Vorschaubilder löschen?"),
                    message: Text("Die Vorschaubilder werden bei Bedarf neu erzeugt. Deine Originalfotos bleiben unverändert."),
                    primaryButton: .destructive(Text("Löschen")) {
                        Task { await store.clearThumbnailCache() }
                    },
                    secondaryButton: .cancel()
                )
            case .rebuildIndex:
                Alert(
                    title: Text("Fotoindex neu aufbauen?"),
                    message: Text("Alle Metadaten werden erneut eingelesen. Vorschaubilder und Originalfotos bleiben erhalten."),
                    primaryButton: .destructive(Text("Neu aufbauen")) {
                        Task { await store.rebuildIndex() }
                    },
                    secondaryButton: .cancel()
                )
            case .deletePeople:
                Alert(
                    title: Text("Alte Personendaten löschen?"),
                    message: Text("Alle früher gespeicherten Namen, Gesichtszuordnungen und biometrischen Embeddings werden aus dem Cache gelöscht. Originalfotos, normale KI-Schlagwörter und Vorschaubilder bleiben erhalten."),
                    primaryButton: .destructive(Text("Altbestand löschen")) {
                        Task { await store.deleteAllPersonData() }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .task {
            await store.updateCacheStatistics()
        }
    }

    private var appearanceSettings: some View {
        Form {
            Picker("Erscheinungsbild", selection: $theme) {
                ForEach(ThemePreference.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("Standard-Gridgröße") {
                HStack {
                    Slider(value: $gridTileSize, in: 110...340, step: 10)
                        .frame(width: 220)
                    Text("\(Int(gridTileSize)) pt")
                        .monospacedDigit()
                        .frame(width: 55, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var cacheSettings: some View {
        Form {
            Section("Speicherort") {
                LabeledContent("Cache-Ordner") {
                    Text(store.cacheDirectoryURL?.path ?? "Nicht festgelegt")
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: 330, alignment: .trailing)
                }

                HStack {
                    Spacer()
                    Button("Im Finder zeigen") {
                        store.revealCacheInFinder()
                    }
                    .disabled(store.cacheDirectoryURL == nil)
                    Button("Ändern …") {
                        Task { await store.chooseCacheLocation() }
                    }
                }
            }

            Section("Begrenzung und Belegung") {
                Picker("Maximaler Cache-Speicher", selection: $cacheSizeLimitGB) {
                    Text("10 GB").tag(10)
                    Text("20 GB").tag(20)
                    Text("50 GB").tag(50)
                    Text("100 GB").tag(100)
                }
                .onChange(of: cacheSizeLimitGB) { _, value in
                    store.updateCacheSizeLimit(value)
                }

                LabeledContent("Fotoindex", value: "\(store.cacheStats.indexedFileCount) Dateien")
                LabeledContent("KI-Analysen", value: "\(store.cacheStats.analyzedPhotoCount) Fotos")
                if store.cacheStats.storedPersonDataCount > 0 {
                    LabeledContent("Alte Personendaten", value: "\(store.cacheStats.storedPersonDataCount) Einträge")
                }
                LabeledContent(
                    "Vorschaubilder",
                    value: "\(store.cacheStats.thumbnailFileCount) Dateien · \(store.cacheStats.formattedThumbnailSize)"
                )
            }

            Section {
                HStack {
                    Button("Vorschaubilder löschen …", role: .destructive) {
                        confirmation = .clearThumbnails
                    }
                    if store.cacheStats.storedPersonDataCount > 0 {
                        Button("Alte Personendaten löschen …", role: .destructive) {
                            confirmation = .deletePeople
                        }
                    }
                    Spacer()
                    Button("Index neu aufbauen …") {
                        confirmation = .rebuildIndex
                    }
                }
            } footer: {
                Text("Beim Wechsel des Speicherorts wird dort ein neuer Index verwendet. Originaldateien werden niemals verschoben oder verändert.")
            }
        }
        .formStyle(.grouped)
    }

    private var softwareUpdateSettings: some View {
        Form {
            Section("RAW Viewer") {
                LabeledContent("Installierte Version", value: store.currentSoftwareVersion)
                updateStatus
            }

            Section {
                HStack {
                    Button("Nach Updates suchen") {
                        store.checkForSoftwareUpdate()
                    }
                    .disabled(isCheckingForSoftwareUpdate || isDownloadingSoftwareUpdate || isSoftwareUpdateReady)

                    if case .available(let update) = store.softwareUpdateStatus {
                        Button("Update laden") {
                            store.downloadSoftwareUpdate(update)
                        }
                    }
                    if case .readyToInstall = store.softwareUpdateStatus,
                       let preparedUpdate = store.preparedSoftwareUpdate {
                        Button("Jetzt installieren") {
                            store.installPreparedSoftwareUpdate(preparedUpdate)
                        }
                    }
                }
            } footer: {
                Text("Updates stammen ausschließlich aus dem offiziellen GitHub-Release. Vor der Installation prüft RAW Viewer Download-Prüfsumme, Bundle-ID und Developer-ID-Signatur.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch store.softwareUpdateStatus {
        case .idle:
            Text("Noch nicht geprüft")
                .foregroundStyle(.secondary)
        case .checking:
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Prüfe auf Updates …")
                }
            }
        case .upToDate:
            LabeledContent("Status", value: "Aktuell")
        case .available(let update):
            LabeledContent("Status", value: "Version \(update.version) verfügbar")
        case .downloading(let update):
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: "Version \(update.version) wird geprüft …")
                }
            }
        case .readyToInstall(let update):
            LabeledContent("Status", value: "Version \(update.version) ist bereit")
        case .failed(let message):
            LabeledContent("Status") {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var isCheckingForSoftwareUpdate: Bool {
        if case .checking = store.softwareUpdateStatus { return true }
        return false
    }

    private var isDownloadingSoftwareUpdate: Bool {
        if case .downloading = store.softwareUpdateStatus { return true }
        return false
    }

    private var isSoftwareUpdateReady: Bool {
        if case .readyToInstall = store.softwareUpdateStatus { return true }
        return false
    }
}

private enum CacheConfirmation: String, Identifiable {
    case clearThumbnails
    case rebuildIndex
    case deletePeople

    var id: String { rawValue }
}
