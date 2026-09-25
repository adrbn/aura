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
        artists = CoverArtists.ranked(mix.songs)
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

    @ViewBuilder
    private func cover(_ spec: MixCoverSpec, _ art: MixCoverArt?) -> some View {
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
}

// MARK: - Radio

/// A radio's cover: its seed artist in the big disc, two artists the radio found around it,
/// on the seed photo's colour. The side discs arrive once the radio has songs.
struct EditorialRadioCover: View {
    /// The radio's songs, seed first.
    let songs: [Song]
    var fallbackName: String = ""
    var size: CGFloat = 200
    var cornerRadius: CGFloat = 12

    /// Tagged with the seed / side artists they were loaded for.
    @State private var lead: (key: String, portrait: CoverPortrait)?
    @State private var sides: (key: String, portraits: [CoverPortrait]) = ("", [])

    private static let sideCandidates = 6

    var body: some View {
        let seed = songs.first.flatMap(CoverArtists.lead(of:))
        let others = Array(CoverArtists.ranked(Array(songs.dropFirst()))
            .filter { $0.id != seed?.id }
            .prefix(Self.sideCandidates))
        let seedKey = seed?.id ?? ""
        let sidesKey = others.map(\.id).joined(separator: ",")
        let current = lead?.key == seedKey ? lead?.portrait
            : seed.flatMap { CoverPortraits.cached($0.id, subject: false) }
        let shownSides = sides.key == sidesKey ? sides.portraits : []
        let name = seed?.name.isEmpty == false ? seed?.name ?? fallbackName : fallbackName
        RadioCoverTemplate(lead: current,
                           left: shownSides.first,
                           right: shownSides.dropFirst().first,
                           name: name,
                           field: current?.band ?? CoverPalette.hashed(name),
                           s: size)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .animation(.easeOut(duration: 0.3), value: shownSides.map(\.artistId))
            .animation(.easeOut(duration: 0.3), value: current?.artistId)
            .task(id: "\(seedKey)#\(ArtworkRetry.shared.generation)") {
                guard let seed, lead?.key != seedKey else { return }
                var result = await CoverPortraits.load(seed, subject: false)
                if result == nil, !Task.isCancelled, let coverArt = songs.first?.displayCoverArt {
                    result = await CoverPortraits.album(coverArt, subject: false)
                }
                if let result, !Task.isCancelled { lead = (seedKey, result) }
            }
            .task(id: "\(sidesKey)#\(ArtworkRetry.shared.generation)") {
                guard sides.key != sidesKey || sides.portraits.count < 2 else { return }
                var found: [CoverPortrait] = []
                for artist in others where found.count < 2 {
                    if Task.isCancelled { return }
                    if let portrait = await CoverPortraits.load(artist, subject: false) { found.append(portrait) }
                }
                if !Task.isCancelled { sides = (sidesKey, found) }
            }
            .accessibilityHidden(true)
    }
}
