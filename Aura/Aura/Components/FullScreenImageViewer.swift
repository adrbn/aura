import SwiftUI
import UIKit

/// Photos-style fullscreen image viewer.
/// - Pinch-to-zoom and double-tap-to-zoom via native UIScrollView
/// - Swipe-down-to-dismiss with rubber-banding background fade
/// - Loads a higher-res version asynchronously while showing the thumbnail
struct FullScreenImageViewer: View {
    let initialImage: UIImage
    let coverArt: String?
    let fallbackURL: URL?
    @Binding var isPresented: Bool

    @State private var hiResImage: UIImage?
    @State private var dragOffset: CGSize = .zero
    @State private var backgroundOpacity: Double = 1.0
    @State private var isZoomed = false

    private var displayImage: UIImage { hiResImage ?? initialImage }

    /// The buttons hide on a single tap, as in Photos, to leave the picture alone.
    @State private var showsChrome = true

    /// 0 at rest, 1 once the picture has been pulled far enough to let go.
    private var dragProgress: CGFloat { min(1, abs(dragOffset.height) / 300) }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            ZoomableImageView(image: displayImage, isZoomed: $isZoomed) {
                withAnimation(.easeOut(duration: 0.2)) { showsChrome.toggle() }
            }
                .ignoresSafeArea()
                // Pulled down, the picture shrinks a little as it goes, like a photo in Photos.
                .scaleEffect(1 - dragProgress * 0.25)
                .offset(dragOffset)
                .gesture(
                    // Drag-to-dismiss only kicks in when not pinch-zoomed
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            guard !isZoomed else { return }
                            // Resist horizontal motion, allow vertical
                            dragOffset = CGSize(width: value.translation.width / 4, height: value.translation.height)
                            backgroundOpacity = max(0.2, 1 - Double(dragProgress))
                        }
                        .onEnded { value in
                            guard !isZoomed else {
                                dragOffset = .zero
                                backgroundOpacity = 1
                                return
                            }
                            let velocity = value.predictedEndTranslation.height
                            if abs(value.translation.height) > 140 || abs(velocity) > 600 {
                                isPresented = false
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    dragOffset = .zero
                                    backgroundOpacity = 1
                                }
                            }
                        }
                )

            chrome
                .opacity(showsChrome && dragOffset == .zero ? 1 : 0)
                .allowsHitTesting(showsChrome)

            ToastOverlay()
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)   // full-bleed black photo viewer
        .sensoryFeedback(.impact(weight: .light), trigger: isZoomed)
        .task { await loadHiRes() }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
            }
            Spacer()
            HStack(spacing: 12) {
                ShareLink(item: Image(uiImage: displayImage),
                          preview: SharePreview("Image", image: Image(uiImage: displayImage))) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(minHeight: 34)
                }
                Button {
                    // The sharpest copy we have: the 1500 px one once it's in, else the thumbnail.
                    Task { await CoverArtSaver.save(displayImage) }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .frame(minHeight: 34)
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
    }

    /// Fetch a larger version of the artwork for crisp pinch-zoom detail.
    private func loadHiRes() async {
        // The deliberate exception to the two-bucket rule: pinch-zoom needs real detail,
        // and this fires once, for a single image, on an explicit user action — not the
        // hundreds-at-once pattern that saturated the server's artwork queue.
        let targetSize = 1500
        if let coverArt, !coverArt.isEmpty,
           let server = ServerManager.shared.currentServer,
           let url = SubsonicClient.shared.coverArtURL(server: server, id: coverArt, size: targetSize) {
            if let img = await fetch(from: url) {
                await MainActor.run { hiResImage = img }
                return
            }
        }
        if let fallbackURL, let img = await fetch(from: fallbackURL) {
            await MainActor.run { hiResImage = img }
        }
    }

    private func fetch(from url: URL) async -> UIImage? {
        do {
            let (data, response) = try await ArtworkCache.shared.imageSession.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}

// MARK: - UIScrollView-backed zoom

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1.0
        scroll.maximumZoomScale = 5.0
        scroll.bouncesZoom = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scroll

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)

        return scroll
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }
        if imageView.image !== image {
            imageView.image = image
        }
        DispatchQueue.main.async {
            context.coordinator.layoutImage(in: scrollView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed, onSingleTap: onSingleTap)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        @Binding var isZoomed: Bool
        let onSingleTap: () -> Void

        init(isZoomed: Binding<Bool>, onSingleTap: @escaping () -> Void) {
            self._isZoomed = isZoomed
            self.onSingleTap = onSingleTap
        }

        @objc func handleSingleTap() { onSingleTap() }

        /// Size and center the image to fit the scroll view bounds (aspect-fit at 1x zoom).
        func layoutImage(in scrollView: UIScrollView) {
            guard let imageView, let image = imageView.image else { return }
            let bounds = scrollView.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }

            let imgSize = image.size
            let widthRatio = bounds.width / imgSize.width
            let heightRatio = bounds.height / imgSize.height
            let scale = min(widthRatio, heightRatio)
            let displaySize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)

            imageView.frame = CGRect(
                x: (bounds.width - displaySize.width) / 2,
                y: (bounds.height - displaySize.height) / 2,
                width: displaySize.width,
                height: displaySize.height
            )
            scrollView.contentSize = bounds.size
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // Keep the image centered while zooming
            guard let imageView else { return }
            let bounds = scrollView.bounds
            let xInset = max(0, (bounds.width - imageView.frame.width) / 2)
            let yInset = max(0, (bounds.height - imageView.frame.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: yInset, left: xInset, bottom: yInset, right: xInset)

            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.001
            if zoomed != isZoomed {
                DispatchQueue.main.async { self.isZoomed = zoomed }
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = scrollView, let imageView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale + 0.001 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let scale = scroll.maximumZoomScale * 0.6  // Photos-style: don't max-out on double tap
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                let rect = CGRect(
                    x: point.x - size.width / 2,
                    y: point.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                scroll.zoom(to: rect, animated: true)
            }
        }
    }
}
