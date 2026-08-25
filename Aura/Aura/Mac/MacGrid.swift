import SwiftUI

/// A cover grid that reflows with the window, plus the loading and empty states that every
/// section needs. Adaptive rather than a fixed column count: the window is resizable, and
/// pinning the columns would either waste an ultrawide or crush a half-screen split.
struct MacGrid<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    var isLoading = false
    var emptyMessage = "Nothing here"
    @ViewBuilder var tile: (Item) -> Tile

    @State private var preferences = MacPreferences.shared

    var body: some View {
        if isLoading && items.isEmpty {
            MacLoadingState()
        } else if items.isEmpty {
            ContentUnavailableView(emptyMessage, systemImage: "music.note")
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: preferences.coverSize.gridMinimum,
                                                 maximum: preferences.coverSize.gridMaximum),
                                       spacing: 20)],
                    spacing: 22
                ) {
                    ForEach(items) { tile($0) }
                }
                .padding(24)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

struct MacLoadingState: View {
    var body: some View {
        BouncingDotsLoader(color: .secondary, dotSize: 11, spacing: 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One cover with its two lines of label. Sized by the grid, not by itself.
struct MacCoverTile: View {
    let coverArt: String?
    let title: String
    var subtitle: String?
    var placeholderName: String?
    var circular = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                CoverArtImage(coverArt: coverArt, size: geo.size.width,
                              cornerRadius: circular ? geo.size.width / 2 : 8,
                              placeholderName: placeholderName)
            }
            .aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: circular ? .center : .leading)
        }
    }
}
