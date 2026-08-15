@preconcurrency import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            Task {
                let status = await SelfTestRunner.run()
                exit(status)
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct RAWViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @AppStorage(PreferenceKeys.theme) private var theme = ThemePreference.system.rawValue

    var body: some Scene {
        WindowGroup("RAW Viewer", id: "library") {
            ContentView(store: store)
                .preferredColorScheme(ThemePreference(rawValue: theme)?.colorScheme)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Fotoordner hinzufügen …") {
                    store.chooseAndAddSources()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(store.isCheckingSourceSize)
            }

            CommandGroup(after: .appInfo) {
                Button("Nach Updates suchen …") {
                    store.checkForSoftwareUpdate()
                }
                .disabled(store.softwareUpdateStatus == .checking || isDownloadingSoftwareUpdate || isSoftwareUpdateReady)
            }

            CommandMenu("Ansicht") {
                Button("Neu einlesen") {
                    store.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.selectedFolderURL == nil)

                Divider()

                Button("Zur Gesamtansicht") {
                    store.closePhoto()
                }
                .keyboardShortcut("g", modifiers: [])
                .disabled(store.viewMode != .photo)

                Button("Ausgewähltes Foto anzeigen") {
                    guard let photo = store.selectedPhoto else { return }
                    store.openPhoto(photo)
                }
                .keyboardShortcut("f", modifiers: [])
                .disabled(store.viewMode != .grid || store.selectedPhoto == nil)

                Divider()

                Button("Vergrößern") {
                    store.zoomIn()
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(store.viewMode != .photo)

                Button("Verkleinern") {
                    store.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(store.viewMode != .photo)

                Button("In Fenster einpassen") {
                    store.fitImage()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(store.viewMode != .photo)
            }

            CommandMenu("Bild") {
                Button(rotationCommandTitle(direction: "links")) {
                    store.rotateSelectedPhotoLeft()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(store.selectedPhotoCount == 0)

                Button(rotationCommandTitle(direction: "rechts")) {
                    store.rotateSelectedPhotoRight()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(store.selectedPhotoCount == 0)

                Divider()

                Button("Ausrichtung zurücksetzen") {
                    store.resetSelectedRotation()
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(!store.canResetSelectedRotation)

                Menu(store.selectedPhotoCount > 1 ? "\(store.selectedPhotoCount) Fotos exportieren" : "Exportieren") {
                    ForEach(PhotoExportFormat.allCases, id: \.self) { format in
                        Button(format.title + " …") {
                            store.exportSelectedPhotos(as: format)
                        }
                    }
                }
                .disabled(store.selectedPhotoCount == 0 || store.isExporting)

                if store.selectedPhotoNeedsXMPSync, let photo = store.selectedPhoto {
                    Button("XMP erneut synchronisieren") {
                        store.retryXMPSync(photo)
                    }
                }
            }

        }

        Settings {
            SettingsView(store: store)
                .preferredColorScheme(ThemePreference(rawValue: theme)?.colorScheme)
        }
    }

    private func rotationCommandTitle(direction: String) -> String {
        store.selectedPhotoCount > 1
            ? "\(store.selectedPhotoCount) Fotos nach \(direction) drehen"
            : "Nach \(direction) drehen"
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
