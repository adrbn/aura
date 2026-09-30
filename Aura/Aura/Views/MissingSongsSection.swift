import SwiftUI

#if !APPSTORE_BUILD

/// Under a library album, the songs of its release the library doesn't have — each to be had
/// on its own, or all at once, so a copy with gaps is made whole. A tap plays a song's preview.
struct MissingSongsSection: View {
    let album: AlbumWithSongs
    let edition: AlbumCompletion.Edition

    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor

    private var release: RadarRelease { edition.release }
    private var missing: [DeezerTrack] { edition.missing(from: album.song ?? []) }

    var body: some View {
        if !missing.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text("Missing")
                    .font(.title2.bold())
                Spacer(minLength: 12)
                getAllButton
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))

            ForEach(missing) { track in
                MissingSongRow(track: track, release: release) { play(track) }
                    .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding, leading: 16,
                                              bottom: AppSettings.shared.listDensity.verticalPadding, trailing: 16))
                    .listRowBackground(Color.clear)
            }
        }
    }

    /// Every missing song in one fetch, and how far along it is.
    private var getAllButton: some View {
        let fetch = ReleaseFetcher.shared.fetch(for: ReleaseFetch.restId(release.id))
        let failed = fetch?.stage == .failed
        return Button {
            ReleaseFetcher.shared.complete(release, missing: missing.map(SoulseekPick.Track.init), album: album.id)
        } label: {
            // Not a Label: in a list its icon takes the list's icon column, far from its title.
            HStack(spacing: 5) {
                Image(systemName: failed ? "arrow.clockwise" : "arrow.down.circle")
                Text(title(of: fetch))
            }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(failed ? AnyShapeStyle(.orange) : AnyShapeStyle(accentColor))
                .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .disabled(fetch?.isActive ?? false)
    }

    private func title(of fetch: ReleaseFetch?) -> String {
        if let fetch, fetch.isActive {
            guard fetch.stage == .downloading, fetch.progress > 0 else { return fetch.headline }
            return "\(fetch.headline) · \(fetch.progress.formatted(.percent.precision(.fractionLength(0))))"
        }
        if fetch?.stage == .failed { return String(localized: "Try Again") }
        return missing.count == 1 ? String(localized: "Get It") : String(localized: "Get All")
    }

    private func play(_ track: DeezerTrack) {
        guard let preview = track.previewSong(of: release) else {
            ToastManager.shared.show(String(localized: "No preview for this song"), icon: "speaker.slash")
            return
        }
        player.playSong(preview, fromQueue: [preview], startIndex: 0, source: .album(id: album.id, name: album.name))
    }
}

/// A song the album is missing, laid out as the album's own rows are, faded — its Get
/// button at full strength.
private struct MissingSongRow: View {
    let track: DeezerTrack
    let release: RadarRelease
    let play: () -> Void

    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor

    private var isCurrent: Bool { player.currentSong?.id == "deezer-\(track.id)" }
    private var length: String {
        guard let seconds = track.duration, seconds > 0 else { return "" }
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(track.track_position.map(String.init) ?? "")
                    .font(.subheadline).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isCurrent ? AnyShapeStyle(accentColor) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    Text(track.artist?.name ?? release.artist.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(length).font(.caption).foregroundStyle(.secondary)
            }
            .opacity(isCurrent ? 1 : 0.45)
            .contentShape(Rectangle())
            .onTapGesture(perform: play)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(track.title), missing, \(length)")
            .accessibilityHint("Plays its preview")
            .accessibilityAddTraits(.isButton)

            SongGetControl(release: release, track: SoulseekPick.Track(track))
                .frame(width: 32)
        }
    }
}

#endif
