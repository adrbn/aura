import Photos
import SwiftUI
import UIKit

/// One action of a cover's long-press menu.
struct CoverMenuAction {
    let title: String
    let systemImage: String
    var isDestructive = false
    let perform: () -> Void
}

extension View {
    /// A long-press menu that lifts this cover alone, in its own shape.
    ///
    /// SwiftUI's `.contextMenu` inside a List belongs to the whole row: the press lifted the
    /// header's title and buttons with the cover, then shrank to the cover at the very end.
    /// This lays UIKit's menu interaction over the cover itself and lifts a picture of it.
    func coverMenu(cornerRadius: CGFloat, actions: [CoverMenuAction]) -> some View {
        overlay(CoverMenuInteraction(cornerRadius: cornerRadius, actions: actions))
            .accessibilityActions {
                ForEach(actions.indices, id: \.self) { index in
                    Button(actions[index].title, action: actions[index].perform)
                }
            }
    }
}

private struct CoverMenuInteraction: UIViewRepresentable {
    let cornerRadius: CGFloat
    let actions: [CoverMenuAction]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.cornerRadius = cornerRadius
        context.coordinator.actions = actions
    }

    @MainActor
    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var cornerRadius: CGFloat = 0
        var actions: [CoverMenuAction] = []
        /// The cover as it was when the press began, lifted and then set back down.
        private var picture: UIImage?

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            let actions = actions
            guard !actions.isEmpty else { return nil }
            picture = nil
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: actions.map { action in
                    UIAction(title: action.title, image: UIImage(systemName: action.systemImage),
                             attributes: action.isDestructive ? .destructive : []) { _ in action.perform() }
                })
            }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            preview(in: interaction.view)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            preview(in: interaction.view)
        }

        /// What's drawn under the overlay — the cover — clipped to its corners and lifted
        /// from where it sits. Taken once, as the press begins: by the time the menu goes,
        /// the screen behind it is blurred.
        private func preview(in view: UIView?) -> UITargetedPreview? {
            guard let view, let window = view.window else { return nil }
            if picture == nil {
                let frame = view.convert(view.bounds, to: window)
                picture = UIGraphicsImageRenderer(size: frame.size).image { _ in
                    window.drawHierarchy(in: CGRect(origin: CGPoint(x: -frame.minX, y: -frame.minY),
                                                    size: window.bounds.size),
                                         afterScreenUpdates: false)
                }
            }
            let imageView = UIImageView(image: picture)
            imageView.frame = view.bounds
            let parameters = UIPreviewParameters()
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: cornerRadius)
            parameters.backgroundColor = .clear
            let target = UIPreviewTarget(container: view, center: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            return UITargetedPreview(view: imageView, parameters: parameters, target: target)
        }
    }
}

/// Puts a cover in the photo library. Aura only ever adds to it, and asks for no more.
///
/// It used to write with `UIImageWriteToSavedPhotosAlbum` and no usage description in the
/// Info.plist, which iOS answers by ending the app on the spot.
@MainActor
enum CoverArtSaver {
    /// The server's picture at full size, from the artwork cache when it's there — so an
    /// album kept on the phone saves offline too.
    static func save(coverArt: String?) {
        guard let coverArt else { return }
        Task {
            let size = ArtworkCache.fullSize
            guard let image = await ArtworkCache.shared.fetchImage(coverArt: coverArt, requestSize: size,
                                                                   key: "\(coverArt)_\(size)") else {
                ToastManager.shared.show("Couldn’t load the cover", icon: "exclamationmark.triangle.fill")
                return
            }
            await save(image)
        }
    }

    /// A cover Aura draws itself, rendered at print size.
    static func save<Cover: View>(rendering cover: Cover) {
        let renderer = ImageRenderer(content: cover)
        renderer.scale = 3
        guard let image = renderer.uiImage else {
            ToastManager.shared.show("Couldn’t save the cover", icon: "exclamationmark.triangle.fill")
            return
        }
        Task { await save(image) }
    }

    private static func save(_ image: UIImage) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            ToastManager.shared.show("Allow Aura to add photos in Settings", icon: "photo.badge.exclamationmark")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            ToastManager.shared.show("Saved to Photos", icon: "checkmark")
        } catch {
            AppLogger.shared.log("❌ Save cover art failed: \(error.localizedDescription)")
            ToastManager.shared.show("Couldn’t save the cover", icon: "exclamationmark.triangle.fill")
        }
    }
}
