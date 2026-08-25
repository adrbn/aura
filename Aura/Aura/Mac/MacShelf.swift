import SwiftUI

/// A horizontal row of cards under a heading — the shelf every streaming service is built
/// out of, because it lets a home page offer a dozen starting points without a single one
/// of them demanding a scroll.
struct MacShelf<Item: Identifiable, Card: View>: View {
    let title: String
    var subtitle: String?
    let items: [Item]
    @ViewBuilder var card: (Item) -> Card

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).auraDisplay(26)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(items) { card($0) }
                    }
                    .padding(.horizontal, 28)
                    // Room for the hover lift, which would otherwise be clipped by the
                    // scroll view's own bounds.
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
            }
            .padding(.bottom, 26)
        }
    }
}

/// A cover that offers to play itself when the pointer is over it.
///
/// The one interaction a desktop music app is expected to have and a phone can't: the card
/// stays a navigation target, and the play button is an extra affordance that costs no
/// permanent space.
struct MacPlayableCard: View {
    let coverArt: String?
    let title: String
    var subtitle: String?
    var placeholderName: String?
    var circular = false
    var width: CGFloat = 164
    /// Drawn instead of the cover — for mixes, which have templated art rather than a file.
    var artwork: AnyView?
    var play: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let artwork {
                        artwork
                    } else {
                        CoverArtImage(coverArt: coverArt, size: width,
                                      cornerRadius: circular ? width / 2 : 8,
                                      placeholderName: placeholderName)
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.45 : 0.25),
                        radius: hovering ? 14 : 6, y: hovering ? 7 : 3)

                if let play {
                    Button(action: play) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.black)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.appAccent))
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .opacity(hovering ? 1 : 0)
                    .offset(y: hovering ? 0 : 10)
                }
            }
            .frame(width: width, height: width)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: width, alignment: circular ? .center : .leading)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}
