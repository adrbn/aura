#if os(iOS)
import SwiftUI

/// Wrapped told one screen at a time, full screen: tap the right side for the next, the
/// left for the one before, hold to pause, swipe down to close. The last screen is the
/// summary, shared as a story-sized picture.
struct WrappedStoryView: View {
    let stats: ListeningStats
    let habits: ListeningHabits?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccentColor) private var accent

    @State private var index = 0
    @State private var progress: Double = 0
    @State private var paused = false
    @State private var dragY: CGFloat = 0
    @State private var images: [String: UIImage] = [:]
    @State private var shareImage: Image?

    private static let slideSeconds = 6.0
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private enum Slide { case intro, artist, songs, album, habits, sound, summary }

    private var slides: [Slide] {
        var out: [Slide] = [.intro]
        if !stats.topArtists.isEmpty { out.append(.artist) }
        if !stats.topSongs.isEmpty { out.append(.songs) }
        if !stats.topAlbums.isEmpty { out.append(.album) }
        if habits != nil { out.append(.habits) }
        if !stats.topGenres.isEmpty { out.append(.sound) }
        out.append(.summary)
        return out
    }

    var body: some View {
        let slide = slides[index]
        ZStack {
            Color(white: 0.07).ignoresSafeArea()
            backdrop(for: slide)
            content(for: slide)
                .id(index)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Tap zones under the bar and the share button.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity)
                    .onTapGesture { go(-1) }
                Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity)
                    .onTapGesture { go(1) }
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.25)
                .onChanged { _ in paused = true }
                .onEnded { _ in paused = false })
            if slide == .summary { shareButton.frame(maxHeight: .infinity, alignment: .bottom) }
            topBar.frame(maxHeight: .infinity, alignment: .top)
        }
        .preferredColorScheme(.dark)
        .offset(y: max(dragY, 0))
        .gesture(DragGesture()
            .onChanged { dragY = $0.translation.height; paused = true }
            .onEnded { value in
                if value.translation.height > 120 { dismiss() } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 1)) { dragY = 0 }
                    paused = false
                }
            })
        .onReceive(tick) { _ in
            guard !paused, slides[index] != .summary else { return }
            progress += 0.05 / Self.slideSeconds
            if progress >= 1 { go(1) }
        }
        .task { await loadImages() }
    }

    private func go(_ step: Int) {
        let next = index + step
        if next >= slides.count { dismiss(); AudioPlayer.askForRatingAtGoodMoment(); return }
        withAnimation(.easeInOut(duration: 0.35)) { index = max(0, next) }
        progress = 0
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Chrome

    private var topBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(slides.indices, id: \.self) { i in
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white)
                            .frame(width: geo.size.width * (i < index ? 1 : i == index ? progress : 0))
                    }
                    .frame(height: 3)
                }
            }
            HStack {
                Text(stats.period.title).font(.subheadline.weight(.semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                }
                .accessibilityLabel("Close")
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var shareButton: some View {
        Group {
            if let shareImage {
                ShareLink(item: shareImage, preview: SharePreview(stats.period.title, image: shareImage)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).padding()
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                }
            } else {
                ProgressView().tint(.white).padding()
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }

    /// The approved top veil, in the slide's own colour.
    private func backdrop(for slide: Slide) -> some View {
        let tint: Color = switch slide {
        case .intro, .summary: accent
        case .artist: Color(red: 0.55, green: 0.35, blue: 0.75)
        case .songs: Color(red: 0.85, green: 0.35, blue: 0.40)
        case .album: Color(red: 0.30, green: 0.55, blue: 0.75)
        case .habits: Color(red: 0.35, green: 0.65, blue: 0.50)
        case .sound: Color(red: 0.85, green: 0.55, blue: 0.30)
        }
        return LinearGradient(colors: [tint.opacity(0.55), .clear], startPoint: .top, endPoint: .center)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.5), value: index)
    }

    // MARK: Slides

    @ViewBuilder
    private func content(for slide: Slide) -> some View {
        switch slide {
        case .intro:
            VStack(spacing: 16) {
                Text(stats.period.coverLabel).font(AppTypography.display(88, relativeTo: .largeTitle))
                    .minimumScaleFactor(0.5).lineLimit(1)
                Text(isYear ? "Your year in music" : "Your month in music")
                    .font(.title3).foregroundStyle(.white.opacity(0.75))
                if stats.totalMinutes > 0 {
                    bigNumber(listeningTime, caption: stats.totalMinutes >= 120 ? "hours of music" : "minutes of music")
                        .padding(.top, 28)
                }
            }
        case .artist:
            let artist = stats.topArtists[0]
            VStack(spacing: 18) {
                caption("Your top artist")
                artwork(id: "artist0", circle: true, size: 240)
                Text(artist.name).font(AppTypography.display(40, relativeTo: .largeTitle))
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                Text("\(artist.plays) plays").font(.headline).foregroundStyle(.white.opacity(0.7))
            }
        case .songs:
            VStack(alignment: .leading, spacing: 14) {
                caption("Your top songs").padding(.bottom, 8)
                ForEach(Array(stats.topSongs.prefix(5).enumerated()), id: \.offset) { i, song in
                    HStack(spacing: 14) {
                        Text("\(i + 1)").font(AppTypography.display(28, relativeTo: .title)).frame(width: 30)
                        artwork(id: "song\(i)", size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).font(.headline).lineLimit(1)
                            Text(song.artist).font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .album:
            let album = stats.topAlbums[0]
            VStack(spacing: 18) {
                caption("Your top album")
                artwork(id: "album0", size: 260)
                VStack(spacing: 4) {
                    Text(album.name).font(AppTypography.display(32, relativeTo: .title))
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    Text(album.artist).font(.headline).foregroundStyle(.white.opacity(0.7))
                }
            }
        case .habits:
            if let habits {
                VStack(alignment: .leading, spacing: 26) {
                    caption("Your habits")
                    if let day = habits.favoriteWeekday {
                        habitRow("Favorite day", Calendar.current.standaloneWeekdaySymbols[day - 1].capitalized)
                    }
                    if let hour = habits.favoriteHour,
                       let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) {
                        habitRow("Favorite time", date.formatted(.dateTime.hour()))
                    }
                    habitRow("Longest streak", String(localized: "\(habits.longestStreak) days in a row"))
                    if let discovery = habits.discovery { habitRow("Your discovery", discovery) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .sound:
            VStack(spacing: 18) {
                caption("Your sound")
                Text(stats.personality).font(AppTypography.display(44, relativeTo: .largeTitle))
                    .multilineTextAlignment(.center).minimumScaleFactor(0.6)
                VStack(spacing: 8) {
                    ForEach(stats.topGenres.prefix(3)) { genre in
                        Text(genre.name).font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.top, 8)
            }
        case .summary:
            summaryCard.frame(maxHeight: 560)
                .padding(.bottom, 70)
        }
    }

    private var isYear: Bool { if case .year = stats.period { true } else { false } }

    private var listeningTime: String {
        stats.totalMinutes >= 120 ? (stats.totalMinutes / 60).formatted() : stats.totalMinutes.formatted()
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
    }

    private func bigNumber(_ value: String, caption: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: value).font(AppTypography.display(64, relativeTo: .largeTitle)).monospacedDigit()
            Text(caption).font(.headline).foregroundStyle(.white.opacity(0.7))
        }
    }

    private func habitRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.white.opacity(0.6))
            Text(verbatim: value).font(AppTypography.display(32, relativeTo: .title)).lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    private func artwork(id: String, circle: Bool = false, size: CGFloat) -> some View {
        let shape = circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size / 10))
        return Group {
            if let image = images[id] {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.08).overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.4)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
    }

    // MARK: Summary (also the shared picture)

    private var summaryCard: some View {
        WrappedSummaryCard(stats: stats, images: images)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .aspectRatio(9 / 16, contentMode: .fit)
    }

    private func renderShareImage() {
        let renderer = ImageRenderer(content: WrappedSummaryCard(stats: stats, images: images)
            .frame(width: 360, height: 640))
        renderer.scale = 3   // 1080 × 1920, a story's size
        if let ui = renderer.uiImage { shareImage = Image(uiImage: ui) }
    }

    // MARK: Pictures

    /// Loaded up front: the shared picture is drawn in one pass and can't wait for them.
    private func loadImages() async {
        var wanted: [(String, String?, String?)] = []
        for (i, a) in stats.topArtists.prefix(5).enumerated() { wanted.append(("artist\(i)", a.serverCoverArt, a.imageURL)) }
        for (i, s) in stats.topSongs.prefix(5).enumerated() { wanted.append(("song\(i)", s.coverArt, s.imageURL)) }
        if let a = stats.topAlbums.first { wanted.append(("album0", a.coverArt, a.imageURL)) }
        let size = ArtworkCache.normalizedSize(900)
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for (id, cover, url) in wanted {
                group.addTask {
                    if let cover {
                        return (id, await ArtworkCache.shared.fetchImage(coverArt: cover, requestSize: size, key: "\(cover)_\(size)"))
                    }
                    if let url = url.flatMap(URL.init(string:)), let (data, _) = try? await URLSession.shared.data(from: url) {
                        return (id, UIImage(data: data))
                    }
                    return (id, nil)
                }
            }
            for await (id, image) in group { if let image { images[id] = image } }
        }
        renderShareImage()
    }
}

/// The summary: top artist up top, the top five artists and songs, time and sound. Drawn
/// at 360 × 640 points, so it shares as a 1080 × 1920 story.
struct WrappedSummaryCard: View {
    let stats: ListeningStats
    let images: [String: UIImage]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image = images["artist0"] {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else { Color(white: 0.15) }
                }
                .frame(width: 360, height: 250)
                .clipped()
                LinearGradient(colors: [.clear, Color(white: 0.07)], startPoint: .center, endPoint: .bottom)
                Text(stats.period.coverLabel)
                    .font(AppTypography.display(52, relativeTo: .largeTitle))
                    .padding(.horizontal, 22).padding(.bottom, 6)
            }
            .frame(width: 360, height: 250)

            HStack(alignment: .top, spacing: 18) {
                column("Top Artists", stats.topArtists.prefix(5).map(\.name))
                column("Top Songs", stats.topSongs.prefix(5).map(\.title))
            }
            .padding(.horizontal, 22).padding(.top, 14)

            Spacer(minLength: 0)

            HStack(alignment: .bottom) {
                if stats.totalMinutes > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listening Time").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                        Text(verbatim: "\((stats.totalMinutes / 60).formatted()) h")
                            .font(AppTypography.display(28, relativeTo: .title))
                    }
                }
                Spacer()
                if let genre = stats.topGenres.first {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Top Genre").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                        Text(verbatim: genre.name).font(AppTypography.display(22, relativeTo: .title)).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 22)

            Text(verbatim: "aura").font(AppTypography.display(16, relativeTo: .caption))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 14)
        }
        .frame(width: 360, height: 640)
        .background(Color(white: 0.07))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func column(_ title: LocalizedStringKey, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "\(i + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    Text(verbatim: name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
