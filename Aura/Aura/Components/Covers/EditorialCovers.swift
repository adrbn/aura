import SwiftUI
import UIKit

// MARK: - Artists of a song list

enum CoverArtists {
    /// The artists of `songs`, most frequent first, ties in order of appearance.
    static func ranked(_ songs: [Song]) -> [ArtistRef] {
        var counts: [String: Int] = [:]
        var order: [ArtistRef] = []
        for song in songs {
            guard let ref = lead(of: song) else { continue }
            if counts[ref.id] == nil { order.append(ref) }
            counts[ref.id, default: 0] += 1
        }
        return order.enumerated()
            .sorted { a, b in
                let (ca, cb) = (counts[a.element.id] ?? 0, counts[b.element.id] ?? 0)
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Mixes shown side by side, each led by an artist none of the ones before it leads. Led
    /// by whoever plays most, the radar and an evening mix both went to the same face. The
    /// artists already leading move to the back rather than out, so a mix made only of them
    /// keeps a cover — and the strip under its title still names them.
    static func distinctLeads(_ mixes: [Mix]) -> [Mix] {
        var leading = Set<String>()
        return mixes.map { mix in
            let order = mix.coverArtists ?? ranked(mix.songs)
            let reordered = order.filter { !leading.contains($0.id) } + order.filter { leading.contains($0.id) }
            if let lead = reordered.first { leading.insert(lead.id) }
            guard reordered.map(\.id) != order.map(\.id) else { return mix }
            return Mix(id: mix.id, title: mix.title, subtitle: mix.subtitle, songs: mix.songs,
                       kind: mix.kind, templateSeed: mix.templateSeed, coverArtists: reordered)
        }
    }

    /// The song's main artist. `artists` credits each name on its own; `artist` runs every
    /// name together, so it only stands in when the server predates the credits.
    static func lead(of song: Song) -> ArtistRef? {
        if let first = song.artists?.first, !first.id.isEmpty { return first }
        guard let id = song.artistId, !id.isEmpty else { return nil }
        return ArtistRef(id: id, name: song.artist ?? "")
    }
}

// MARK: - Mix

/// What a mix's cover shows, worked out from the mix alone.
struct MixCoverSpec {
    enum Template {
        case mix(kicker: String, title: String)
        case genre(words: [String])
        case year(period: String)
    }

    let template: Template
    /// Most-played first; the first with a photo leads the cover.
    let artists: [ArtistRef]
    let seed: String
    /// The lead artist's album cover, for when the catalogue has no photo of anyone.
    let fallbackCoverArt: String?

    /// Artists tried for the photo before settling for an album cover.
    private static let photoCandidates = 3

    init(_ mix: Mix) {
        seed = mix.id
        artists = mix.coverArtists ?? CoverArtists.ranked(mix.songs)
        let leadId = artists.first?.id
        fallbackCoverArt = (mix.songs.first { CoverArtists.lead(of: $0)?.id == leadId } ?? mix.songs.first)?
            .displayCoverArt
        let key = mix.templateSeed ?? ""
        switch mix.kind ?? .generic {
        case .genre:
            let words = (mix.templateSeed ?? mix.title)
                .split(whereSeparator: { $0 == " " || $0 == "/" })
                .prefix(3).map(String.init)
            template = .genre(words: words.isEmpty ? [mix.title] : words)
        case .timeOfDay:
            template = .mix(kicker: String(localized: "Mix"), title: Self.daypart(key))
        case .mood:
            template = .mix(kicker: String(localized: "Mix"), title: Self.mood(key))
        case .discovery:
            template = .mix(kicker: String(localized: "For You"), title: String(localized: "Discoveries"))
        case .radar:
            template = .mix(kicker: String(localized: "New Releases"), title: String(localized: "Radar"))
        case .retrospective:
            template = .year(period: mix.templateSeed ?? mix.title)
        case .generic:
            template = .mix(kicker: String(localized: "Mix"), title: mix.title)
        }
    }

    var candidates: [ArtistRef] { Array(artists.prefix(Self.photoCandidates)) }

    /// The colour the cover is built on, for the page around it.
    func accent(_ art: MixCoverArt?) -> UIColor {
        switch template {
        case .mix: return art?.portrait.band ?? CoverPalette.hashed(seed)
        case .genre: return CoverPalette.duotone(for: seed).light
        case .year: return CoverPalette.ui(0xC2185B)
        }
    }

    var needsSubject: Bool {
        if case .year = template { return true }
        return false
    }

    /// Changes whenever the cover would: another template or another lead artist.
    var taskKey: String { "\(seed)|\(candidates.map(\.id).joined(separator: ","))" }

    private static func daypart(_ key: String) -> String {
        switch key {
        case "morning": return String(localized: "Morning")
        case "afternoon": return String(localized: "Afternoon")
        case "evening": return String(localized: "Evening")
        default: return String(localized: "Late Night")
        }
    }

    private static func mood(_ key: String) -> String {
        switch key {
        case "chill": return String(localized: "Chill")
        case "focus": return String(localized: "Focus")
        case "feel_good": return String(localized: "Feel Good")
        default: return String(localized: "Energy")
        }
    }
}

/// A photo read for a mix cover, with the genre treatment already applied when needed.
struct MixCoverArt {
    let portrait: CoverPortrait
    let duotone: UIImage?
    let duotoneTopIsLight: Bool

    private final class Box: @unchecked Sendable {
        let art: MixCoverArt
        init(_ art: MixCoverArt) { self.art = art }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 48
        return cache
    }()

    static func cached(_ spec: MixCoverSpec) -> MixCoverArt? {
        cache.object(forKey: spec.taskKey as NSString)?.art
    }

    static func load(_ spec: MixCoverSpec) async -> MixCoverArt? {
        if let hit = cached(spec) { return hit }
        var found = await CoverPortraits.first(of: spec.candidates, subject: spec.needsSubject)
        if found == nil, !Task.isCancelled, let coverArt = spec.fallbackCoverArt {
            found = await CoverPortraits.album(coverArt, subject: spec.needsSubject)
        }
        guard let portrait = found else { return nil }
        var art = MixCoverArt(portrait: portrait, duotone: nil, duotoneTopIsLight: false)
        if case .genre = spec.template {
            let pair = CoverPalette.duotone(for: spec.seed)
            art = await Task.detached(priority: .utility) {
                let tinted = CoverImaging.duotone(portrait.image, dark: pair.dark, light: pair.light)
                let top = tinted?.cgImage.map { CoverImaging.average(of: $0, from: 0, to: 0.15) }
                return MixCoverArt(portrait: portrait, duotone: tinted,
                                   duotoneTopIsLight: top.map { CoverPalette.luminance($0) > 0.5 } ?? false)
            }.value
        }
        cache.setObject(Box(art), forKey: spec.taskKey as NSString)
        return art
    }
}

/// A mix's cover in the editorial system: the most-played artist's photo, framed on the face,
/// under the mix's type treatment. Draws a complete typographic cover until — or unless —
/// a photo arrives.
struct EditorialMixCover: View {
    let mix: Mix
    var size: CGFloat = 160
    var cornerRadius: CGFloat = 12

    /// Tagged with the spec it was loaded for, so a regenerated mix never shows the old one.
    @State private var loaded: (key: String, art: MixCoverArt)?

    var body: some View {
        let spec = MixCoverSpec(mix)
        let art = loaded?.key == spec.taskKey ? loaded?.art : MixCoverArt.cached(spec)
        cover(spec, art)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .animation(.easeOut(duration: 0.3), value: art?.portrait.artistId)
            .task(id: "\(spec.taskKey)#\(ArtworkRetry.shared.generation)") {
                guard loaded?.key != spec.taskKey else { return }
                guard let result = await MixCoverArt.load(spec), !Task.isCancelled else { return }
                loaded = (spec.taskKey, result)
            }
            .accessibilityHidden(true)
    }

    private func cover(_ spec: MixCoverSpec, _ art: MixCoverArt?) -> some View {
        Self.template(spec, art, size: size)
    }

    @ViewBuilder
    static func template(_ spec: MixCoverSpec, _ art: MixCoverArt?, size: CGFloat) -> some View {
        switch spec.template {
        case .mix(let kicker, let title):
            MixCoverTemplate(portrait: art?.portrait, kicker: kicker, title: title,
                             artists: spec.artists.map(\.name).filter { !$0.isEmpty },
                             band: art?.portrait.band ?? CoverPalette.hashed(spec.seed), s: size)
        case .genre(let words):
            let pair = CoverPalette.duotone(for: spec.seed)
            GenreCoverTemplate(portrait: art?.portrait, duotone: art?.duotone, words: words,
                               kicker: String(localized: "Mix"), dark: pair.dark, light: pair.light,
                               topIsLight: art?.duotoneTopIsLight ?? false, s: size)
        case .year(let period):
            YearCoverTemplate(portrait: art?.portrait, period: period,
                              kicker: String(localized: "Wrapped"), s: size)
        }
    }

    /// The mix's cover as a JPEG, photo in, for a playlist saved from it.
    @MainActor
    static func jpeg(of mix: Mix) async -> Data? {
        let spec = MixCoverSpec(mix)
        let art = await MixCoverArt.load(spec)
        return CoverRendering.jpeg(template(spec, art, size: CoverRendering.side))
    }
}

// MARK: - Radio

/// What a radio's cover shows, worked out from its songs alone.
struct RadioCoverSpec {
    let seed: ArtistRef?
    /// Artists the radio found around the seed, most frequent first.
    let others: [ArtistRef]
    let name: String
    let seedCoverArt: String?

    private static let sideCandidates = 6

    init(songs: [Song], fallbackName: String) {
        seed = songs.first.flatMap(CoverArtists.lead(of:))
        let seedId = seed?.id
        others = Array(CoverArtists.ranked(Array(songs.dropFirst()))
            .filter { $0.id != seedId }
            .prefix(Self.sideCandidates))
        name = seed?.name.isEmpty == false ? seed?.name ?? fallbackName : fallbackName
        seedCoverArt = songs.first?.displayCoverArt
    }

    var seedKey: String { seed?.id ?? "" }
    var sidesKey: String { others.map(\.id).joined(separator: ",") }

    /// The seed's photo, else the seed song's album cover.
    func lead() async -> CoverPortrait? {
        guard let seed else { return nil }
        if let portrait = await CoverPortraits.load(seed, subject: false) { return portrait }
        guard !Task.isCancelled, let seedCoverArt else { return nil }
        return await CoverPortraits.album(seedCoverArt, subject: false)
    }

    /// The first two artists around the seed with a photo, and the names for the strip —
    /// the top two, when none has one.
    func sides() async -> (portraits: [CoverPortrait], names: [String]) {
        var found: [CoverPortrait] = []
        var names: [String] = []
        for artist in others where found.count < 2 {
            if Task.isCancelled { break }
            if let portrait = await CoverPortraits.load(artist, subject: false) {
                found.append(portrait)
                names.append(artist.name)
            }
        }
        return (found, names.isEmpty ? others.prefix(2).map(\.name) : names)
    }

    func template(lead: CoverPortrait?, sides: [CoverPortrait], names: [String], isLoading: Bool,
                  size: CGFloat) -> RadioCoverTemplate {
        RadioCoverTemplate(lead: lead, left: sides.first, right: sides.dropFirst().first, name: name,
                           artists: names, field: lead?.band ?? CoverPalette.hashed(name),
                           isLoading: isLoading, s: size)
    }

    /// The cover as a JPEG, photos in, for a playlist saved from the radio.
    @MainActor
    func jpeg() async -> Data? {
        async let lead = lead()
        async let sides = sides()
        let (portrait, around) = await (lead, sides)
        return CoverRendering.jpeg(template(lead: portrait, sides: around.portraits, names: around.names,
                                            isLoading: false, size: CoverRendering.side))
    }
}

/// A radio's cover: its seed artist in the big disc, two artists the radio found around it,
/// on the seed photo's colour. The side discs arrive once the radio has songs.
struct EditorialRadioCover: View {
    /// The radio's songs, seed first.
    let songs: [Song]
    var fallbackName: String = ""
    var size: CGFloat = 200
    var cornerRadius: CGFloat = 12
    /// The radio is still being put together: its rings travel.
    var isLoading = false

    /// Tagged with the seed / side artists they were loaded for.
    @State private var lead: (key: String, portrait: CoverPortrait)?
    @State private var sides: (key: String, portraits: [CoverPortrait], names: [String]) = ("", [], [])

    var body: some View {
        let spec = RadioCoverSpec(songs: songs, fallbackName: fallbackName)
        let seedKey = spec.seedKey
        let sidesKey = spec.sidesKey
        let current = lead?.key == seedKey ? lead?.portrait
            : spec.seed.flatMap { CoverPortraits.cached($0.id, subject: false) }
        let shownSides = sides.key == sidesKey ? sides.portraits : []
        spec.template(lead: current, sides: shownSides, names: sides.key == sidesKey ? sides.names : [],
                      isLoading: isLoading, size: size)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .animation(.easeOut(duration: 0.3), value: shownSides.map(\.artistId))
            .animation(.easeOut(duration: 0.3), value: current?.band)
            .animation(.easeOut(duration: 0.3), value: current?.artistId)
            .task(id: "\(seedKey)#\(ArtworkRetry.shared.generation)") {
                guard spec.seed != nil, lead?.key != seedKey else { return }
                if let result = await spec.lead(), !Task.isCancelled { lead = (seedKey, result) }
            }
            .task(id: "\(sidesKey)#\(ArtworkRetry.shared.generation)") {
                guard sides.key != sidesKey || sides.portraits.count < 2 else { return }
                let found = await spec.sides()
                if !Task.isCancelled { sides = (sidesKey, found.portraits, found.names) }
            }
            .accessibilityHidden(true)
    }
}
