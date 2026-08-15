@preconcurrency import AppKit
import SwiftUI

struct PhotoDetailView: View {
    let asset: PhotoAsset
    @ObservedObject var store: LibraryStore
    @State private var renderedImage: RenderedImage?
    @State private var renderedAssetID: String?
    @State private var errorMessage: String?
    @State private var isRendering = false
    @State private var isMagnifying = false
    @State private var magnificationStart = 1.0
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollOffset = CGPoint.zero
    @State private var panStartOffset: CGPoint?
    @State private var isPointerOverImage = false
    @State private var focusRequestToken = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                    .ignoresSafeArea()

                if let renderedImage {
                    zoomableImage(renderedImage, viewport: geometry.size)
                } else if let errorMessage {
                    errorView(errorMessage)
                } else {
                    ProgressView("Bild wird geladen …")
                }

                if isRendering, renderedImage != nil {
                    VStack {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                                .background(.regularMaterial, in: Circle())
                        }
                        Spacer()
                    }
                    .padding()
                }

                if let errorMessage, renderedImage != nil {
                    VStack {
                        Spacer()
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                            .padding()
                    }
                }

                VStack {
                    Spacer()
                    HStack {
                        Text(asset.filename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(asset.typeLabel)
                            .foregroundStyle(.secondary)
                        let rotation = store.rotation(for: asset)
                        if rotation != .none {
                            Label(rotation.title, systemImage: "rotate.right")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.viewerFitsWindow {
                            Text("Eingepasst")
                        } else {
                            Text("\(Int(store.viewerZoom * 100)) %")
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.bar)
                }
            }
            .task(id: renderTaskID(viewport: geometry.size)) {
                await loadImage(viewport: geometry.size)
            }
        }
        .background {
            FirstResponderBridge(
                requestToken: focusRequestToken,
                isEnabled: store.viewMode == .photo,
                handleKeyDown: handleKeyDown
            )
            .frame(width: 0, height: 0)
        }
        .onAppear {
            requestKeyboardFocus()
        }
        .onChange(of: asset.id) { _, _ in
            resetPanPosition()
            requestKeyboardFocus()
        }
        .onChange(of: store.rotation(for: asset)) { _, _ in
            store.fitImage()
            resetPanPosition()
            requestKeyboardFocus()
        }
        .onDisappear {
            NSCursor.arrow.set()
        }
        .photoContextMenu(asset: asset, store: store)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 53:
            store.handleEscapeKey()
        case 123:
            store.showPreviousPhoto()
        case 124:
            store.showNextPhoto()
        default:
            return false
        }
        return true
    }

    private func requestKeyboardFocus() {
        guard store.viewMode == .photo else { return }
        Task { @MainActor in
            await Task.yield()
            guard store.viewMode == .photo else { return }
            focusRequestToken &+= 1
        }
    }

    private func zoomableImage(_ rendered: RenderedImage, viewport: CGSize) -> some View {
        let rotation = store.rotation(for: asset)
        let displayPixelSize = rotation.displaySize(for: rendered.pixelSize)
        let fitScale = min(
            max(0.01, (viewport.width - 32) / displayPixelSize.width),
            max(0.01, (viewport.height - 64) / displayPixelSize.height)
        )
        let scale = store.viewerFitsWindow ? min(1, fitScale) : store.viewerZoom
        let unrotatedSize = CGSize(
            width: max(1, rendered.pixelSize.width * scale),
            height: max(1, rendered.pixelSize.height * scale)
        )
        let displaySize = rotation.displaySize(for: unrotatedSize)
        let width = displaySize.width
        let height = displaySize.height
        let maximumOffset = CGPoint(
            x: max(0, width - viewport.width),
            y: max(0, height - viewport.height)
        )
        let canPan = maximumOffset.x > 0 || maximumOffset.y > 0

        return ScrollView([.horizontal, .vertical]) {
            RotatedPhotoImage(
                image: rendered.image,
                rotation: rotation,
                unrotatedSize: unrotatedSize
            )
                .frame(
                    minWidth: max(1, viewport.width),
                    minHeight: max(1, viewport.height - 30),
                    alignment: .center
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if store.viewerFitsWindow {
                        store.actualSize()
                    } else {
                        store.fitImage()
                    }
                }
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGPoint.self) { geometry in
            geometry.contentOffset
        } action: { _, newOffset in
            scrollOffset = newOffset
        }
        .scrollIndicators(.automatic)
        .onHover { isInside in
            isPointerOverImage = isInside
            updatePanCursor(canPan: canPan)
        }
        .onChange(of: canPan) { _, newValue in
            if !newValue {
                panStartOffset = nil
            }
            updatePanCursor(canPan: newValue)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard canPan else { return }

                    if panStartOffset == nil {
                        panStartOffset = scrollOffset
                        NSCursor.closedHand.set()
                    }

                    guard let startOffset = panStartOffset else { return }
                    scrollPosition.scrollTo(
                        x: min(maximumOffset.x, max(0, startOffset.x - value.translation.width)),
                        y: min(maximumOffset.y, max(0, startOffset.y - value.translation.height))
                    )
                }
                .onEnded { _ in
                    panStartOffset = nil
                    updatePanCursor(canPan: canPan)
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if !isMagnifying {
                        isMagnifying = true
                        magnificationStart = store.viewerFitsWindow ? max(0.25, fitScale) : store.viewerZoom
                    }
                    store.viewerFitsWindow = false
                    store.viewerZoom = min(8, max(0.25, magnificationStart * value.magnification))
                }
                .onEnded { _ in
                    isMagnifying = false
                }
        )
    }

    private func resetPanPosition() {
        scrollPosition = ScrollPosition()
        scrollOffset = .zero
        panStartOffset = nil
        updatePanCursor(canPan: false)
    }

    private func updatePanCursor(canPan: Bool) {
        if panStartOffset != nil {
            NSCursor.closedHand.set()
        } else if canPan, isPointerOverImage {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Foto kann nicht angezeigt werden", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("\(asset.filename)\n\(message)")
        } actions: {
            Button("Zurück zur Gesamtansicht") {
                store.closePhoto()
            }
        }
    }

    private func renderTaskID(viewport: CGSize) -> String {
        "\(asset.id)|\(targetPixelSize(viewport: viewport))"
    }

    private func targetPixelSize(viewport: CGSize) -> Int {
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2
        let zoom = store.viewerFitsWindow ? 1 : max(1, store.viewerZoom)
        let requested = Int(max(viewport.width, viewport.height) * backingScale * zoom)
        let bucket = max(2_048, ((requested + 1_023) / 1_024) * 1_024)
        return min(12_288, bucket)
    }

    @MainActor
    private func loadImage(viewport: CGSize) async {
        let target = targetPixelSize(viewport: viewport)
        if renderedAssetID != asset.id {
            renderedImage = nil
            renderedAssetID = asset.id
            errorMessage = nil
        }
        isRendering = true
        defer { isRendering = false }

        var displayedPreview = false
        if renderedImage == nil,
           let thumbnailPreview = await store.thumbnailPreview(for: asset) {
            guard !Task.isCancelled else { return }
            renderedImage = thumbnailPreview
            displayedPreview = true
        }

        if asset.rawURL != nil, !asset.companionURLs.isEmpty {
            do {
                let preview = try await store.renderImage(
                    url: asset.previewURL,
                    isRAW: false,
                    maxPixelSize: min(2_048, target)
                )
                try Task.checkCancellation()
                renderedImage = preview
                displayedPreview = true
            } catch is CancellationError {
                return
            } catch {
                // The RAW pass below still has a chance to produce an image.
            }
        }

        if displayedPreview {
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
        }

        do {
            let image = try await store.renderImage(
                url: asset.rawURL ?? asset.primaryURL,
                isRAW: asset.rawURL != nil,
                maxPixelSize: target
            )
            try Task.checkCancellation()
            renderedImage = image
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
