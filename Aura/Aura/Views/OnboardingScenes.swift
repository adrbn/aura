import SwiftUI

/// The onboarding's headline: bold sans, with the words between asterisks in an italic
/// serif, like the site's "For the library *you* host." Translations keep the asterisks
/// around their own word.
struct OnboardingTitle: View {
    let key: String.LocalizationValue
    var size: CGFloat = 34
    var weight: Font.Weight = .bold

    var body: some View {
        var text = AttributedString(localized: key)
        // Last run first, so the hair space added after each one leaves the earlier ranges valid.
        let emphasized = text.runs.filter { $0.inlinePresentationIntent?.contains(.emphasized) == true }.map(\.range)
        for range in emphasized.reversed() {
            var word = AttributedString(String(text[range].characters))
            word.font = .system(size: size * 1.14, weight: .regular, design: .serif).italic()
            // The italic leans into the next word; a hair space gives it room.
            word.append(AttributedString("\u{200A}"))
            text.replaceSubrange(range, with: word)
        }
        return Text(text)
            .font(.system(size: size, weight: weight))
            .tracking(size > 24 ? -0.6 : 0)
            .lineSpacing(size > 24 ? -2 : 2)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Columns of album covers tilted to the left, every other one drifting up while its
/// neighbours drift down. The covers are Deezer's album chart for wherever the phone is
/// (Deezer picks the country from the connection); without a network, plain colour tiles.
struct CoverWall: View {
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var gaveUp = false
    private var images: [UIImage] { CoverWallStore.shared.images }

    private let columns = 5
    private let perColumn = 7
    private let loop: Double = 26
    private let gap: CGFloat = 10
    private static let fallback: [Color] = [
        .init(red: 0.89, green: 0.28, blue: 0.24), .init(red: 0.18, green: 0.36, blue: 0.54),
        .init(red: 0.84, green: 0.64, blue: 0.23), .init(red: 0.42, green: 0.25, blue: 0.63),
        .init(red: 0.12, green: 0.48, blue: 0.36), .init(red: 0.76, green: 0.22, blue: 0.42),
        .init(red: 0.72, green: 0.34, blue: 0.16),
    ]

    var body: some View {
        GeometryReader { geo in
            let tile = (geo.size.width * 0.3).rounded()
            let columnHeight = CGFloat(perColumn) * (tile + gap)
            TimelineView(.animation(paused: reduceMotion || !active)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0..<columns, id: \.self) { column in
                        let phase = ((t + Double(column) * 4) / loop).truncatingRemainder(dividingBy: 1)
                        let y = column.isMultiple(of: 2) ? -phase * columnHeight : (phase - 1) * columnHeight
                        VStack(spacing: gap) {
                            // Twice the column, so the loop never shows its end.
                            ForEach(0..<perColumn * 2, id: \.self) { row in
                                cover(column * perColumn + row % perColumn, size: tile)
                            }
                        }
                        .offset(y: y)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .offset(y: -geo.size.height * 0.1)
                .rotationEffect(.degrees(-12))
                .rotation3DEffect(.degrees(14), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                .rotation3DEffect(.degrees(8), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .black, location: 0.12),
                                         .init(color: .black, location: 0.42),
                                         .init(color: .clear, location: 0.7)],
                                 startPoint: .top, endPoint: .bottom))
        }
        // Nothing until the covers are in, then all of them at once: colour tiles swapping
        // to covers one by one read as a broken screen. Plain tiles only if Deezer never answers.
        .opacity(images.isEmpty && !gaveUp ? 0 : 1)
        .animation(.easeOut(duration: 0.6), value: images.isEmpty)
        .animation(.easeOut(duration: 0.6), value: gaveUp)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            await CoverWallStore.shared.load()
            if images.isEmpty { gaveUp = true }
        }
    }

    @ViewBuilder
    private func cover(_ index: Int, size: CGFloat) -> some View {
        Group {
            if images.isEmpty {
                Self.fallback[index % Self.fallback.count].opacity(0.55)
            } else {
                Image(uiImage: images[index % images.count]).resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
    }

    private struct Chart: Decodable {
        struct Album: Decodable { let cover_medium: String? }
        let data: [Album]
    }

    /// Deezer's album chart covers as image data, in chart order, skipping any that fail.
    static func chartCoverData() async -> [Data] {
        guard let url = URL(string: "https://api.deezer.com/chart/0/albums?limit=35"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let chart = try? JSONDecoder().decode(Chart.self, from: data)
        else { return [] }
        let urls = chart.data.compactMap { $0.cover_medium.flatMap(URL.init(string:)) }
        return await loadData(urls)
    }

    static func loadImages(_ urls: [URL]) async -> [UIImage] {
        await loadData(urls).compactMap(UIImage.init(data:))
    }

    static func loadData(_ urls: [URL]) async -> [Data] {
        await withTaskGroup(of: (Int, Data?).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          UIImage(data: data) != nil else { return (i, nil) }
                    return (i, data)
                }
            }
            var found: [(Int, Data)] = []
            for await (i, data) in group { if let data { found.append((i, data)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

/// The welcome wall's covers, fetched while the splash is still up and kept on disk, so
/// the first screen never shows an empty wall. The disk copy shows at once on later
/// launches and the chart is refreshed behind it.
@MainActor @Observable
final class CoverWallStore {
    static let shared = CoverWallStore()
    private(set) var images: [UIImage] = []
    private var task: Task<Void, Never>?

    private static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WelcomeCovers", isDirectory: true)

    /// Starts the fetch once; every caller waits for the same one.
    func load() async {
        if task == nil {
            task = Task {
                let cached = Self.readCache()
                if !cached.isEmpty { images = cached }
                let fresh = await CoverWall.chartCoverData()
                guard !fresh.isEmpty else { return }
                if images.isEmpty { images = fresh.compactMap(UIImage.init(data:)) }
                Self.writeCache(fresh)
            }
        }
        await task?.value
    }

    private static func readCache() -> [UIImage] {
        (0..<35).compactMap { i in
            (try? Data(contentsOf: folder.appendingPathComponent("\(i).jpg"))).flatMap(UIImage.init(data:))
        }
    }

    private static func writeCache(_ covers: [Data]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, data) in covers.enumerated() {
            try? data.write(to: folder.appendingPathComponent("\(i).jpg"))
        }
    }
}

/// Right after the server answers: the user's own covers come into focus from big blocks
/// while the album count climbs, then "Start Listening" saves the server and opens the app.
struct LibraryFoundView: View {
    let server: ServerConfig
    var onStart: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var covers: [UIImage] = []
    @State private var albumCount: Int?
    @State private var revealStart: Date?

    private let duration: Double = 2.4
    private let maxBlock: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.animation(paused: revealStart == nil || reduceMotion)) { context in
                let p = progress(at: context.date)
                VStack(alignment: .leading, spacing: 0) {
                    grid
                        .layerEffect(ShaderLibrary.auraPixellate(.float(block(p))),
                                     maxSampleOffset: CGSize(width: maxBlock, height: maxBlock))
                        .opacity(revealStart == nil ? 0 : 1)
                        .overlay { if revealStart == nil { ProgressView().tint(.white) } }
                    Spacer(minLength: 24)
                    if let albumCount {
                        Text(verbatim: Int((Double(albumCount) * p).rounded()).formatted())
                            .font(.system(size: 56, weight: .bold))
                            .monospacedDigit()
                            .tracking(-1)
                            .foregroundStyle(.white)
                        Text("albums found. Aura reads the rest in the background.")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.64))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    } else if revealStart != nil {
                        OnboardingTitle(key: "Your library is ready.")
                    }
                }
            }
            Button(action: onStart) {
                Text("Start Listening")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.white)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.top, 32)
            .padding(.bottom, 52)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .task { await load() }
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<25, id: \.self) { i in
                Group {
                    if i < covers.count {
                        Image(uiImage: covers[i]).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .accessibilityHidden(true)
    }

    private func progress(at date: Date) -> Double {
        guard let revealStart else { return 0 }
        if reduceMotion { return 1 }
        return min(1, date.timeIntervalSince(revealStart) / duration)
    }

    /// Big blocks that shrink fast, then settle into sharp covers.
    private func block(_ p: Double) -> CGFloat {
        1 + (maxBlock - 1) * CGFloat(pow(1 - p, 3))
    }

    private func load() async {
        let count = Task { try? await SubsonicClient.shared.getAlbumCount(server: server) }
        let images = Task { () -> [UIImage] in
            let albums = (try? await SubsonicClient.shared.getAlbumList2(server: server, type: "random", size: 25)) ?? []
            let urls = albums.compactMap { album in
                album.coverArt.flatMap { SubsonicClient.shared.coverArtURL(server: server, id: $0, size: 200) }
            }
            return await CoverWall.loadImages(urls)
        }
        // The reveal starts with the covers, or after 6 s without them: a slow server (the
        // public demo) left the screen on grey blocks. Late covers and count still come in.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await images.value }
            group.addTask { try? await Task.sleep(for: .seconds(6)) }
            await group.next()
            group.cancelAll()
        }
        Task { covers = await images.value }
        revealStart = Date()
        albumCount = await count.value
    }

}
