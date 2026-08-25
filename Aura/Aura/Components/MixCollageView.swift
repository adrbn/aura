import SwiftUI

/// A 1- or 4-up collage of cover art for a mix thumbnail.
struct MixCollageView: View {
    let coverArts: [String]
    var size: CGFloat = 160
    var cornerRadius: CGFloat = 12

    var body: some View {
        Group {
            if coverArts.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        CoverArtImage(coverArt: coverArts[0], size: size / 2, cornerRadius: 0)
                        CoverArtImage(coverArt: coverArts[1], size: size / 2, cornerRadius: 0)
                    }
                    HStack(spacing: 0) {
                        CoverArtImage(coverArt: coverArts[2], size: size / 2, cornerRadius: 0)
                        CoverArtImage(coverArt: coverArts[3], size: size / 2, cornerRadius: 0)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                CoverArtImage(coverArt: coverArts.first, size: size, cornerRadius: cornerRadius)
            }
        }
    }
}
