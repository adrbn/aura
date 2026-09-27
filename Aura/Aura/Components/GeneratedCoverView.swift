import SwiftUI

/// Procedurally-generated cover art for content that has no server artwork —
/// genre mixes, time-of-day mixes, and month/year retrospectives. The look is
/// driven by the content's *nature* so each category reads distinctly at a glance
/// ("cover avec template par nature de contenu").
struct GeneratedCoverView: View {
    enum Nature: Hashable {
        case genre(String)          // genre name, e.g. "Rock"
        case daypart(String)        // "morning" | "afternoon" | "evening" | "night"
        case mood(String)           // Mood.rawValue, e.g. "chill"
        case retrospective(String)  // period label, e.g. "2026" or "June 2026"
    }

    let nature: Nature
    var size: CGFloat = 160
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            // Base gradient keyed to the content nature.
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)

            // Large decorative glyph bleeding off the top-right corner.
            Image(systemName: icon)
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(.white.opacity(0.22))
                .rotationEffect(.degrees(-12))
                .offset(x: size * 0.22, y: -size * 0.20)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)

            // Legibility scrim at the bottom for the label.
            LinearGradient(
                colors: [.clear, .black.opacity(0.35)],
                startPoint: .center, endPoint: .bottom
            )

            // Foreground label (hidden on very small thumbnails where it'd be noise).
            if size >= 70 {
                VStack(alignment: .leading, spacing: 2) {
                    Spacer()
                    if let kicker {
                        Text(kicker.uppercased())
                            .font(.system(size: max(size * 0.07, 9), weight: .heavy))
                            .foregroundStyle(.white.opacity(0.7))
                            .tracking(1)
                    }
                    Text(label)
                        .font(.system(size: max(size * 0.13, 14), weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(size * 0.09)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    // MARK: - Template resolution

    private var label: String {
        switch nature {
        case .genre(let g): return g
        case .daypart(let d): return Self.daypartTitle(d)
        case .mood(let m): return Self.moodTitle(m)
        case .retrospective(let period): return period
        }
    }

    private var kicker: String? {
        switch nature {
        case .genre: return "Genre Mix"
        case .daypart: return "For Right Now"
        case .mood: return "Mood"
        case .retrospective: return "Your Wrapped"
        }
    }

    private var icon: String {
        switch nature {
        case .genre(let g): return Self.genreIcon(g)
        case .daypart(let d): return Self.daypartIcon(d)
        case .mood(let m): return Self.moodIcon(m)
        case .retrospective: return "sparkles"
        }
    }

    private var palette: [Color] {
        switch nature {
        case .genre(let g): return Self.genrePalette(g)
        case .daypart(let d): return Self.daypartPalette(d)
        case .mood(let m): return Self.moodPalette(m)
        case .retrospective: return [Color(hue: 0.78, saturation: 0.75, brightness: 0.85),
                                     Color(hue: 0.92, saturation: 0.80, brightness: 0.80),
                                     Color(hue: 0.05, saturation: 0.85, brightness: 0.90)]
        }
    }

    // MARK: - Genre (derived from a stable hash so a genre's colour never changes)

    /// Process-stable hash (Swift's `hashValue` is randomised per launch).
    static func stableHash(_ s: String) -> Int {
        var h = 5381
        for b in s.lowercased().utf8 { h = ((h &* 33) &+ Int(b)) & 0x7fffffff }
        return h
    }

    /// A stable two-stop gradient derived from any string seed. Shared by genre
    /// mixes and the generic missing-art placeholder so a given name always maps
    /// to the same colours.
    static func hashedPalette(_ seed: String) -> [Color] {
        let hue = Double(stableHash(seed) % 360) / 360.0
        return [
            Color(hue: hue, saturation: 0.72, brightness: 0.82),
            Color(hue: (hue + 0.09).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 0.62)
        ]
    }

    private static func genrePalette(_ genre: String) -> [Color] { hashedPalette(genre) }

    private static func genreIcon(_ genre: String) -> String {
        let g = genre.lowercased()
        let map: [(String, String)] = [
            ("rock", "guitars"), ("metal", "guitars"), ("punk", "guitars"),
            ("classic", "pianokeys"), ("piano", "pianokeys"), ("jazz", "pianokeys"),
            ("hip", "music.mic"), ("rap", "music.mic"), ("r&b", "music.mic"), ("soul", "music.mic"),
            ("electro", "waveform"), ("house", "waveform"), ("techno", "waveform"),
            ("dance", "waveform"), ("edm", "waveform"), ("trance", "waveform"),
            ("acoustic", "guitars"), ("folk", "guitars"), ("country", "guitars"),
            ("ambient", "waveform.path"), ("lo-fi", "waveform.path"), ("lofi", "waveform.path"),
            ("pop", "star.fill")
        ]
        return map.first(where: { g.contains($0.0) })?.1 ?? "music.note"
    }

    // MARK: - Daypart

    private static func daypartTitle(_ d: String) -> String {
        switch d {
        case "morning": return "Morning Mix"
        case "afternoon": return "Afternoon Mix"
        case "evening": return "Evening Mix"
        default: return "Late Night Mix"
        }
    }

    private static func daypartIcon(_ d: String) -> String {
        switch d {
        case "morning": return "sunrise.fill"
        case "afternoon": return "sun.max.fill"
        case "evening": return "sunset.fill"
        default: return "moon.stars.fill"
        }
    }

    private static func daypartPalette(_ d: String) -> [Color] {
        switch d {
        case "morning":   return [Color(hue: 0.09, saturation: 0.55, brightness: 0.98),
                                  Color(hue: 0.03, saturation: 0.70, brightness: 0.85)]
        case "afternoon": return [Color(hue: 0.55, saturation: 0.65, brightness: 0.95),
                                  Color(hue: 0.50, saturation: 0.80, brightness: 0.70)]
        case "evening":   return [Color(hue: 0.92, saturation: 0.55, brightness: 0.80),
                                  Color(hue: 0.78, saturation: 0.70, brightness: 0.55)]
        default:          return [Color(hue: 0.66, saturation: 0.70, brightness: 0.45),
                                  Color(hue: 0.70, saturation: 0.85, brightness: 0.22)]
        }
    }

    // MARK: - Mood

    private static func moodTitle(_ m: String) -> String {
        switch m {
        case "chill": return "Chill Mix"
        case "focus": return "Focus Mix"
        case "feel_good": return "Feel Good Mix"
        default: return "Energy Mix"
        }
    }

    private static func moodIcon(_ m: String) -> String {
        switch m {
        case "chill": return "leaf.fill"
        case "focus": return "scope"
        case "feel_good": return "face.smiling.fill"
        default: return "bolt.fill"
        }
    }

    private static func moodPalette(_ m: String) -> [Color] {
        switch m {
        case "chill":     return [Color(hue: 0.48, saturation: 0.55, brightness: 0.80),
                                  Color(hue: 0.55, saturation: 0.70, brightness: 0.55)]
        case "focus":     return [Color(hue: 0.62, saturation: 0.55, brightness: 0.78),
                                  Color(hue: 0.66, saturation: 0.75, brightness: 0.45)]
        case "feel_good": return [Color(hue: 0.08, saturation: 0.70, brightness: 0.97),
                                  Color(hue: 0.95, saturation: 0.65, brightness: 0.80)]
        default:          return [Color(hue: 0.02, saturation: 0.78, brightness: 0.92),
                                  Color(hue: 0.07, saturation: 0.88, brightness: 0.78)]
        }
    }
}

/// A mix thumbnail that uses a templated generated cover when the mix has a
/// distinct nature (genre / time-of-day / mood / retrospective), and otherwise
/// falls back to a song-cover collage (discovery / generic mixes).
struct MixCoverView: View {
    let mix: Mix
    var size: CGFloat = 160
    var cornerRadius: CGFloat = 12

    var body: some View {
        if let nature = mix.generatedCover {
            GeneratedCoverView(nature: nature, size: size, cornerRadius: cornerRadius)
        } else {
            MixCollageView(coverArts: mix.collageCoverArts, size: size, cornerRadius: cornerRadius)
        }
    }
}

/// Templated placeholder for library items that have no server artwork
/// (artist / album / song / playlist). A stable name-seeded gradient with a
/// kind glyph, so missing art reads as intentional instead of a grey box.
struct PlaceholderCoverView: View {
    enum Kind { case artist, album, song, playlist, generic }

    let seed: String
    var kind: Kind = .generic
    var size: CGFloat = 50
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            LinearGradient(colors: GeneratedCoverView.hashedPalette(seed),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: glyph)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.18), radius: max(1, size * 0.02), y: 1)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var glyph: String {
        switch kind {
        case .artist:   return "music.mic"
        case .album:    return "opticaldisc.fill"
        case .song:     return "music.note"
        case .playlist: return "music.note.list"
        case .generic:  return "music.note"
        }
    }
}

// MARK: - Playlist cover

/// A playlist's picture: the retrospective template when Aura made it, the server's
/// artwork otherwise.
///
/// One view rather than a check at each of the dozen places a playlist cover is drawn —
/// the rule belongs in one place, and every list, grid and header then gets it for free.
struct PlaylistCoverView: View {
    /// Taken apart rather than passed a `Playlist`, because the detail screen holds a
    /// `PlaylistWithSongs` and both need to draw the same picture.
    let playlistId: String
    let coverArt: String?
    var cacheToken: String? = nil
    var size: CGFloat
    var cornerRadius: CGFloat = 12
    /// Seeds the gradient shown when the server has no picture for it.
    var placeholderName: String? = nil

    var body: some View {
        if let period = WrappedCovers.period(for: playlistId) {
            GeneratedCoverView(nature: .retrospective(period.coverLabel),
                               size: size, cornerRadius: cornerRadius)
        } else {
            CoverArtImage(coverArt: coverArt, size: size,
                          cornerRadius: cornerRadius, cacheToken: cacheToken,
                          placeholderName: placeholderName, placeholderKind: .playlist)
        }
    }
}
