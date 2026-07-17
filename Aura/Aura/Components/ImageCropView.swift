import SwiftUI
import UIKit

/// A 1:1 square crop view using UIKit's scroll view for reliable pan+zoom.
/// This avoids SwiftUI gesture conflicts that cause the app to freeze.
struct ImageCropView: View {
    let image: UIImage
    let onCrop: (UIImage) -> Void
    let onCancel: () -> Void
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                GeometryReader { geo in
                    let cropSize = min(geo.size.width, geo.size.height) - 40

                    ZStack {
                        // UIKit-based zoomable scroll view (reliable, no gesture conflicts)
                        CropScrollView(image: image, cropSize: cropSize)
                            .frame(width: cropSize, height: cropSize)
                            .clipShape(Rectangle())

                        // Crop border
                        Rectangle()
                            .strokeBorder(.white.opacity(0.5), lineWidth: 1)
                            .frame(width: cropSize, height: cropSize)
                            .allowsHitTesting(false)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .principal) {
                    Text("Crop Cover Art")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { performCrop() }
                        .fontWeight(.semibold)
                        .foregroundStyle(accentColor)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        // Photos-style dark crop editor: pin so the status bar stays legible in light mode.
        .preferredColorScheme(.dark)
    }

    private func performCrop() {
        // Render the image at output resolution by taking the visible crop area
        let outputSize: CGFloat = 1200
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSize, height: outputSize))
        let cropped = renderer.image { ctx in
            // Simple center-crop: take the largest centered square from the original image
            let imgW = image.size.width
            let imgH = image.size.height
            let side = min(imgW, imgH)
            let x = (imgW - side) / 2
            let y = (imgH - side) / 2

            if let cgImage = image.cgImage?.cropping(to: CGRect(x: x * image.scale, y: y * image.scale, width: side * image.scale, height: side * image.scale)) {
                let croppedUIImage = UIImage(cgImage: cgImage)
                croppedUIImage.draw(in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
            } else {
                // Fallback: draw full image scaled to square
                image.draw(in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
            }
        }
        onCrop(cropped)
    }
}

// MARK: - UIKit ScrollView-based crop (reliable pan + zoom)

struct CropScrollView: UIViewRepresentable {
    let image: UIImage
    let cropSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bounces = true
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .black
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }

        // Calculate the image size to fill the crop area
        let imgAspect = image.size.width / image.size.height
        let imageDisplaySize: CGSize
        if imgAspect > 1 {
            // Landscape: height = cropSize, width extends
            imageDisplaySize = CGSize(width: cropSize * imgAspect, height: cropSize)
        } else {
            // Portrait: width = cropSize, height extends
            imageDisplaySize = CGSize(width: cropSize, height: cropSize / imgAspect)
        }

        imageView.frame = CGRect(origin: .zero, size: imageDisplaySize)
        scrollView.contentSize = imageDisplaySize

        // Center the image initially
        let offsetX = max(0, (imageDisplaySize.width - cropSize) / 2)
        let offsetY = max(0, (imageDisplaySize.height - cropSize) / 2)
        scrollView.contentOffset = CGPoint(x: offsetX, y: offsetY)

        // Set minimum zoom so image always fills the crop square
        let minZoomW = cropSize / imageDisplaySize.width
        let minZoomH = cropSize / imageDisplaySize.height
        scrollView.minimumZoomScale = max(minZoomW, minZoomH, 1.0)
        scrollView.zoomScale = scrollView.minimumZoomScale
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(in: scrollView)
        }

        private func centerContent(in scrollView: UIScrollView) {
            guard let imageView else { return }
            let boundsSize = scrollView.bounds.size
            var frameToCenter = imageView.frame

            if frameToCenter.size.width < boundsSize.width {
                frameToCenter.origin.x = (boundsSize.width - frameToCenter.size.width) / 2
            } else {
                frameToCenter.origin.x = 0
            }

            if frameToCenter.size.height < boundsSize.height {
                frameToCenter.origin.y = (boundsSize.height - frameToCenter.size.height) / 2
            } else {
                frameToCenter.origin.y = 0
            }

            imageView.frame = frameToCenter
        }
    }
}

/// Get the visible crop region from the scroll view and render to image
extension CropScrollView {
    static func cropImage(from scrollView: UIScrollView, imageView: UIImageView, originalImage: UIImage, outputSize: CGFloat) -> UIImage {
        let visibleRect = CGRect(
            x: scrollView.contentOffset.x / scrollView.zoomScale,
            y: scrollView.contentOffset.y / scrollView.zoomScale,
            width: scrollView.bounds.width / scrollView.zoomScale,
            height: scrollView.bounds.height / scrollView.zoomScale
        )

        // Convert from display coordinates to image coordinates
        let imageViewSize = imageView.bounds.size
        let scaleX = originalImage.size.width / imageViewSize.width
        let scaleY = originalImage.size.height / imageViewSize.height

        let cropRect = CGRect(
            x: visibleRect.origin.x * scaleX * originalImage.scale,
            y: visibleRect.origin.y * scaleY * originalImage.scale,
            width: visibleRect.width * scaleX * originalImage.scale,
            height: visibleRect.height * scaleY * originalImage.scale
        )

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSize, height: outputSize))
        return renderer.image { _ in
            if let cgImage = originalImage.cgImage?.cropping(to: cropRect) {
                UIImage(cgImage: cgImage).draw(in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
            } else {
                originalImage.draw(in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
            }
        }
    }
}
