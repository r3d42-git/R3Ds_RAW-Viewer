import SwiftUI

struct ContentView: View {
    @ObservedObject var store: LibraryStore
    @AppStorage(PreferenceKeys.collectionLayout) private var collectionLayout = PhotoCollectionLayout.grid

    var body: some View {
        Group {
            if store.isCacheConfigured {
                libraryView
            } else {
                CacheSetupView(store: store)
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .task {
            await store.prepareCacheIfNeeded()
        }
        .task {
            await store.checkLMStudioAtLaunch()
        }
        .task {
            store.checkForSoftwareUpdateAtLaunch()
        }
        .alert(item: $store.actionError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(item: $store.largePhotoSourceWarning) { warning in
            Alert(
                title: Text("Sehr großer Fotoordner"),
                message: Text(warning.message),
                primaryButton: .default(Text("Trotzdem hinzufügen")) {
                    store.confirmAddingLargePhotoSources()
                },
                secondaryButton: .cancel(Text("Abbrechen")) {
                    store.cancelAddingLargePhotoSources()
                }
            )
        }
        .alert(item: $store.xmpExportSuggestion) { suggestion in
            Alert(
                title: Text("XMP-Sidecars schreiben?"),
                message: Text(suggestion.message),
                primaryButton: .default(Text("XMP schreiben")) {
                    store.confirmXMPExportSuggestion()
                },
                secondaryButton: .cancel(Text("Später")) {
                    store.dismissXMPExportSuggestion()
                }
            )
        }
        .alert(item: $store.softwareUpdatePrompt) { update in
            Alert(
                title: Text(verbatim: "RAW Viewer \(update.version) ist verfügbar"),
                message: Text("Das Update wird von GitHub geladen und vor der Installation mit SHA-256 und der Developer-ID-Signatur geprüft."),
                primaryButton: .default(Text("Laden und prüfen")) {
                    store.downloadSoftwareUpdate(update)
                },
                secondaryButton: .cancel(Text("Später")) {
                    store.dismissSoftwareUpdatePrompt()
                }
            )
        }
        .alert(item: $store.preparedSoftwareUpdatePrompt) { preparedUpdate in
            Alert(
                title: Text(verbatim: "Update \(preparedUpdate.update.version) ist bereit"),
                message: Text("RAW Viewer wird beendet, durch die geprüfte Version ersetzt und anschließend neu gestartet."),
                primaryButton: .default(Text("Installieren und neu starten")) {
                    store.installPreparedSoftwareUpdate(preparedUpdate)
                },
                secondaryButton: .cancel(Text("Später")) {
                    store.dismissPreparedSoftwareUpdatePrompt()
                }
            )
        }
    }

    private var libraryView: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 210, ideal: 270, max: 420)
        } detail: {
            DetailView(store: store)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    store.chooseAndAddSources()
                } label: {
                    Label("Fotoordner hinzufügen", systemImage: "folder.badge.plus")
                }
                .disabled(store.isCheckingSourceSize)
                .help("Fotoordner hinzufügen (⌘O)")

                if store.isCheckingSourceSize {
                    ProgressView()
                        .controlSize(.small)
                        .help("Fotoanzahl einschließlich Unterordnern wird geprüft")
                }

                Button {
                    store.refresh()
                } label: {
                    Label("Neu einlesen", systemImage: "arrow.clockwise")
                }
                .disabled(store.selectedFolderURL == nil || store.isScanning)
                .help("Ausgewählten Ordner neu einlesen (⌘R)")

                if store.viewMode == .photo {
                    Button(action: store.showPreviousPhoto) {
                        Image(systemName: "chevron.left")
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!store.canShowPrevious)
                    .help("Vorheriges Foto (←)")

                    Button(action: store.showNextPhoto) {
                        Image(systemName: "chevron.right")
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!store.canShowNext)
                    .help("Nächstes Foto (→)")
                }
            }

            if store.selectedFolderURL != nil {
                ToolbarItem(placement: .principal) {
                    Picker("Ansicht", selection: toolbarViewSelection) {
                        Label("Raster", systemImage: "square.grid.3x3")
                            .labelStyle(.iconOnly)
                            .tag(ToolbarViewSelection.grid)
                            .accessibilityLabel("Rasteransicht")
                        Label("Blocksatz", systemImage: "rectangle.split.3x1")
                            .labelStyle(.iconOnly)
                            .tag(ToolbarViewSelection.justified)
                            .accessibilityLabel("Blocksatzansicht")
                        Label("Einzelbild", systemImage: "photo")
                            .labelStyle(.iconOnly)
                            .tag(ToolbarViewSelection.photo)
                            .accessibilityLabel("Einzelbildansicht")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    .help("Raster, Blocksatz oder ausgewähltes Einzelbild anzeigen")
                }
            }

            if store.selectedPhotoCount > 0 {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: store.rotateSelectedPhotoLeft) {
                        Image(systemName: "rotate.left")
                    }
                    .accessibilityLabel("Nach links drehen")
                    .help(rotationHelp(direction: "links", shortcut: "⌥⌘←"))

                    Button(action: store.rotateSelectedPhotoRight) {
                        Image(systemName: "rotate.right")
                    }
                    .accessibilityLabel("Nach rechts drehen")
                    .help(rotationHelp(direction: "rechts", shortcut: "⌥⌘→"))

                    Menu {
                        ForEach(PhotoExportFormat.allCases, id: \.self) { format in
                            Button(format.title + " …") {
                                store.exportSelectedPhotos(as: format)
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Ausgewählte Fotos exportieren")
                    .help(store.selectedPhotoCount == 1
                        ? "Ausgewähltes Foto exportieren"
                        : "\(store.selectedPhotoCount) ausgewählte Fotos exportieren")
                    .disabled(store.isExporting)
                }
            }

            if store.viewMode == .photo {
                ToolbarItemGroup(placement: .primaryAction) {

                    Button("Einpassen", action: store.fitImage)
                        .help("In Fenster einpassen (⌘0)")
                    Button("100 %", action: store.actualSize)

                    Button(action: store.zoomOut) {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    Slider(
                        value: Binding(
                            get: { store.viewerZoom },
                            set: {
                                store.viewerFitsWindow = false
                                store.viewerZoom = $0
                            }
                        ),
                        in: 0.25...8
                    )
                    .frame(width: 110)
                    .help("Zoom \(Int(store.viewerZoom * 100)) %")
                    Button(action: store.zoomIn) {
                        Image(systemName: "plus.magnifyingglass")
                    }

                    Button(action: WindowActions.toggleFullScreen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Vollbild")
                }
            }
        }
    }

    private func rotationHelp(direction: String, shortcut: String) -> String {
        if store.selectedPhotoCount == 1 {
            return "Nach \(direction) drehen (\(shortcut))"
        }
        return "\(store.selectedPhotoCount) Fotos nach \(direction) drehen (\(shortcut))"
    }

    private var toolbarViewSelection: Binding<ToolbarViewSelection> {
        Binding(
            get: {
                if store.viewMode == .photo { return .photo }
                return collectionLayout == .grid ? .grid : .justified
            },
            set: { selection in
                switch selection {
                case .grid:
                    collectionLayout = .grid
                    if store.viewMode == .photo { store.closePhoto() }
                case .justified:
                    collectionLayout = .justified
                    if store.viewMode == .photo { store.closePhoto() }
                case .photo:
                    guard let photo = store.selectedPhoto else { return }
                    store.openPhoto(photo)
                }
            }
        )
    }
}

private enum ToolbarViewSelection: Hashable {
    case grid
    case justified
    case photo
}

private struct CacheSetupView: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        ContentUnavailableView {
            Label("Cache-Speicherort festlegen", systemImage: "externaldrive.badge.plus")
        } description: {
            VStack(spacing: 8) {
                Text("RAW Viewer speichert dort den Fotoindex und Vorschaubilder. Deine Originaldateien werden nicht verändert.")
                Text("Für beste Leistung empfiehlt sich ein Ordner auf einer lokalen SSD.")
                if let error = store.cacheSetupError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 560)
        } actions: {
            Button("Cache-Ordner auswählen …") {
                Task { await store.chooseCacheLocation() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isConfiguringCache)
        }
    }
}
