#if os(iOS)
import CarPlay

/// What the car browses, as the phone's tabs lay it out: the Home — Made For You with the
/// radar leading, then what was played lately — the playlists with the favourites first, and
/// the library's newest albums. Each opens as the phone's detail pages do, Play and Shuffle
/// above the songs, and starting anything brings up Now Playing.
@MainActor
final class CarPlayBrowser {
    private weak var interfaceController: CPInterfaceController?
    private let player = AudioPlayer.shared
    /// The song rows on screen and the song each plays, so the playing mark follows the song.
    private let songRows = NSMapTable<CPListItem, NSString>.weakToStrongObjects()
    /// Rows a list is built with at most — each fetches its cover. Play and Shuffle still play
    /// the whole of it; nobody scrolls further than this at a red light.
    private static var rowLimit: Int { min(200, Int(CPListTemplate.maximumItemCount)) }

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func tabBar() -> CPTabBarTemplate {
        let tabs = [home(), playlists(), library()]
        return CPTabBarTemplate(templates: Array(tabs.prefix(Int(CPTabBarTemplate.maximumTabCount))))
    }

    // MARK: - Tabs

    private func home() -> CPListTemplate {
        let template = tab(String(localized: "Home"), symbol: "house.fill")
        Task {
            async let recent = albums("recent", count: 12)
            let mixes = await madeForYou()
            var sections: [CPListSection] = []
            if !mixes.isEmpty {
                // The name as the section's header, not the row's: a row's title reads as a
                // link, and there is no page beyond the covers to go to.
                sections.append(CPListSection(items: [await shelf(mixes)],
                                              header: String(localized: "Made For You"), sectionIndexTitle: nil))
            }
            let played = await recent
            if !played.isEmpty {
                sections.append(CPListSection(items: played.map(albumRow),
                                              header: String(localized: "Recently Played"), sectionIndexTitle: nil))
            }
            fill(template, with: sections)
        }
        return template
    }

    private func playlists() -> CPListTemplate {
        let template = tab(String(localized: "Playlists"), symbol: "music.note.list")
        Task {
            let favourites = WatchItem(kind: .favorites, id: "favorites", title: String(localized: "Favorites"),
                                       subtitle: String(localized: "Your starred songs"), coverArt: nil)
            var pinned = [row(favourites, placeholder: "heart.fill", tint: CarPlayArtwork.accent)]
            var others: [CPListItem] = []
            if let server = ServerManager.shared.currentServer {
                do {
                    let found = try await SubsonicClient.shared.getPlaylists(server: server)
                    let settings = AppSettings.shared
                    let playlistRow = { (playlist: Playlist) in
                        self.row(LibraryCatalog.item(playlist), placeholder: "music.note.list")
                    }
                    pinned += Self.pinnedFirst(found.filter { settings.isPinned($0.id) }).map(playlistRow)
                    others = found.filter { !settings.isPinned($0.id) }
                        .sorted { ($0.changed ?? "") > ($1.changed ?? "") }
                        .map(playlistRow)
                } catch {
                    AppLogger.shared.log("🚗 Playlists not loaded: \(error.localizedDescription)")
                }
            }
            fill(template, with: [CPListSection(items: pinned), CPListSection(items: others)])
        }
        return template
    }

    private func library() -> CPListTemplate {
        let template = tab(String(localized: "Library"), symbol: "square.stack.fill")
        let shuffle = action(String(localized: "Shuffle Library"), symbol: "shuffle") { [weak self] in
            await self?.shuffleLibrary()
        }
        template.updateSections([CPListSection(items: [shuffle])])
        Task {
            let newest = await albums("newest", count: 24)
            guard !newest.isEmpty else { return }
            fill(template, with: [
                CPListSection(items: [shuffle]),
                CPListSection(items: newest.map(albumRow),
                              header: String(localized: "Recently Added"), sectionIndexTitle: nil),
            ])
        }
        return template
    }

    private func tab(_ title: String, symbol: String) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.tabTitle = title
        template.tabImage = UIImage(systemName: symbol)
        template.emptyViewTitleVariants = [String(localized: "Loading…")]
        return template
    }

    /// The sections, cut to what the car allows; an empty list says why it's empty.
    private func fill(_ template: CPListTemplate, with sections: [CPListSection]) {
        var room = Int(CPListTemplate.maximumItemCount)
        let kept = sections.prefix(Int(CPListTemplate.maximumSectionCount)).compactMap { section -> CPListSection? in
            guard room > 0 else { return nil }
            let items = Array(section.items.prefix(room))
            room -= items.count
            return CPListSection(items: items, header: section.header, sectionIndexTitle: nil)
        }
        template.emptyViewTitleVariants = [ServerManager.shared.currentServer == nil
            ? String(localized: "Sign in to Aura on your iPhone")
            : String(localized: "Nothing here yet")]
        template.updateSections(kept)
    }

    // MARK: - Made For You

    /// The pinned playlists in the order they were pinned in, as the phone lists them.
    private static func pinnedFirst(_ playlists: [Playlist]) -> [Playlist] {
        let order = AppSettings.shared.pinnedPlaylistOrder
        return playlists.sorted {
            (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max)
        }
    }

    /// The Home's shelf: the generated mixes, the radar first once it has found something,
    /// no two covers on the same artist's face.
    private func madeForYou() async -> [Mix] {
        await MixGenerator.shared.generateIfNeeded()
        let mixes = MixGenerator.shared.mixes
        guard AppSettings.shared.radarEnabled, let radar = RadarService.shared.current,
              !radar.releases.isEmpty else { return CoverArtists.distinctLeads(mixes) }
        return CoverArtists.distinctLeads([radar.mix] + mixes)
    }

    /// The mixes as a row of their covers — no caption, as on the phone: the cover already
    /// prints the name. Drawn typographic at once, their photos laid in as they come.
    private func shelf(_ mixes: [Mix]) async -> CPListImageRowItem {
        let scale = interfaceController?.carTraitCollection.displayScale ?? 2
        var covers: [UIImage] = []
        for mix in mixes {
            covers.append(await CarPlayArtwork.mixCover(mix, photo: false, scale: scale))
        }
        let row = CPListImageRowItem(text: nil, elements: Self.elements(covers), allowsMultipleLines: true)
        row.listImageRowHandler = { [weak self] row, index, completion in
            guard let self, mixes.indices.contains(index) else { return completion() }
            let cover = row.elements.indices.contains(index) ? row.elements[index].image : nil
            Task {
                await self.open(LibraryCatalog.item(mixes[index]), cover: cover)
                completion()
            }
        }
        Task { [weak row] in
            var photos: [UIImage] = []
            for mix in mixes {
                photos.append(await CarPlayArtwork.mixCover(mix, photo: true, scale: scale))
            }
            row?.elements = Self.elements(photos)
        }
        return row
    }

    private static func elements(_ covers: [UIImage]) -> [CPListImageRowItemRowElement] {
        covers.map { CPListImageRowItemRowElement(image: $0, title: nil, subtitle: nil) }
    }

    // MARK: - Detail

    /// A mix, a playlist, the favourites or an album, as its page on the phone: Play and
    /// Shuffle, then its songs. From iOS 26.4 the cover heads the page, Play and Shuffle
    /// under it as Apple Music has them; before, they are its first two rows.
    func open(_ item: WatchItem, cover: UIImage? = nil) async {
        let songs = await LibraryCatalog.songs(of: item)
        // One song has no page to browse: it plays.
        if songs.count == 1 { return await play(songs, of: item, at: 0, shuffled: false) }
        let template = CPListTemplate(title: item.title, sections: [])
        template.emptyViewTitleVariants = [String(localized: "Nothing to play")]
        if !songs.isEmpty {
            let playAll: () async -> Void = { [weak self] in
                await self?.play(songs, of: item, at: 0, shuffled: false)
            }
            let shuffleAll: () async -> Void = { [weak self] in
                await self?.play(songs, of: item, at: 0, shuffled: true)
            }
            // Every song on an album shares its cover: the rows go without.
            let rows = songs.prefix(max(0, Self.rowLimit - 2)).enumerated().map { index, song in
                songRow(song, showsCover: item.kind != .album) { [weak self] in
                    await self?.play(songs, of: item, at: index, shuffled: false)
                }
            }
            var sections = [CPListSection(items: rows)]
            if #available(iOS 26.4, *) {
                template.listHeader = await header(item, cover: cover, play: playAll, shuffle: shuffleAll)
            } else {
                sections.insert(CPListSection(items: [
                    action(String(localized: "Play"), symbol: "play.fill", perform: playAll),
                    action(String(localized: "Shuffle"), symbol: "shuffle", perform: shuffleAll),
                ]), at: 0)
            }
            fill(template, with: sections)
        }
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// The page's head: its cover — the favourites' heart where it has none — its name, and
    /// Play and Shuffle, over a background drawn from the cover.
    @available(iOS 26.4, *)
    private func header(_ item: WatchItem, cover: UIImage?, play: @escaping () async -> Void,
                        shuffle: @escaping () async -> Void) async -> CPListTemplateDetailsHeader {
        var picture = cover
        if picture == nil { picture = await CarPlayArtwork.cover(item.coverArt) }
        let thumbnail = picture ?? (item.kind == .favorites
            ? CarPlayArtwork.glyph("heart.fill", tint: CarPlayArtwork.accent)
            : CarPlayArtwork.glyph("music.note.list"))
        let buttons = [(String(localized: "Play"), "play.fill", play),
                       (String(localized: "Shuffle"), "shuffle", shuffle)].map { title, symbol, perform in
            let button = CPButton(image: CarPlayArtwork.symbol(symbol)) { _ in Task { await perform() } }
            button.title = title
            return button
        }
        let header = CPListTemplateDetailsHeader(thumbnail: CPThumbnailImage(image: thumbnail), title: item.title,
                                                 subtitle: item.subtitle.isEmpty ? nil : item.subtitle,
                                                 actionButtons: buttons)
        header.wantsAdaptiveBackgroundStyle = picture != nil
        return header
    }

    // MARK: - Up Next

    /// The queue as the phone lists it: what was queued by hand, then what plays on. A tap
    /// plays that song and returns to Now Playing.
    func showUpNext() {
        let queued = player.userQueue.prefix(Self.rowLimit).enumerated().map { slot, song in
            songRow(song, showsCover: true) { [weak self] in self?.playUpcoming(song, slot: slot, queued: true) }
        }
        let first = player.queueIndex + 1
        let onward = player.queue.indices.contains(first) ? Array(player.queue[first...]) : []
        let autoplay = onward.prefix(Self.rowLimit - queued.count).enumerated().map { offset, song in
            songRow(song, showsCover: true) { [weak self] in
                self?.playUpcoming(song, slot: first + offset, queued: false)
            }
        }
        let template = CPListTemplate(title: String(localized: "Up Next"), sections: [])
        var sections: [CPListSection] = []
        if !queued.isEmpty {
            sections.append(CPListSection(items: queued, header: String(localized: "Next in Queue"),
                                          sectionIndexTitle: nil))
        }
        if !autoplay.isEmpty {
            sections.append(CPListSection(items: autoplay, header: String(localized: "Autoplay"),
                                          sectionIndexTitle: nil))
        }
        fill(template, with: sections)
        template.emptyViewTitleVariants = [String(localized: "Nothing in the queue")]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func playUpcoming(_ song: Song, slot: Int, queued: Bool) {
        LibraryCatalog.playUpcoming(song.id, slot: slot, queued: queued)
        showNowPlaying()
    }

    // MARK: - Playing

    /// Marks the row of the song now playing, wherever it's listed.
    func markPlaying() {
        let current = player.currentSong?.id
        for case let row as CPListItem in songRows.keyEnumerator().allObjects {
            row.isPlaying = songRows.object(forKey: row) as String? == current
        }
    }

    private func play(_ songs: [Song], of item: WatchItem, at index: Int, shuffled: Bool) async {
        await LibraryCatalog.play(songs, of: item, at: index, shuffled: shuffled)
        showNowPlaying()
    }

    private func shuffleLibrary() async {
        guard let server = ServerManager.shared.currentServer else { return }
        do {
            let songs = try await SubsonicClient.shared.getRandomSongs(server: server, size: 100)
            guard let first = songs.first else { return }
            player.playSong(first, fromQueue: songs, source: .songs)
            showNowPlaying()
        } catch {
            AppLogger.shared.log("🚗 Library shuffle not loaded: \(error.localizedDescription)")
        }
    }

    /// Brings Now Playing forward — back to it when it's already open under a list, never a
    /// second copy of it on the stack.
    func showNowPlaying() {
        guard let controller = interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if controller.topTemplate === nowPlaying { return }
        if controller.templates.contains(where: { $0 === nowPlaying }) {
            controller.pop(to: nowPlaying, animated: true, completion: nil)
        } else {
            controller.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }

    // MARK: - Rows

    private func albums(_ type: String, count: Int) async -> [Album] {
        guard let server = ServerManager.shared.currentServer else { return [] }
        do {
            return try await SubsonicClient.shared.getAlbumList2(server: server, type: type, size: count)
        } catch {
            AppLogger.shared.log("🚗 Albums (\(type)) not loaded: \(error.localizedDescription)")
            return []
        }
    }

    /// An album's row: a single plays straight away, anything longer opens its page.
    private func albumRow(_ album: Album) -> CPListItem {
        let item = LibraryCatalog.item(album)
        guard album.songCount == 1 else { return row(item, placeholder: "square.stack") }
        let row = CPListItem(text: item.title, detailText: item.subtitle.isEmpty ? nil : item.subtitle,
                             image: CarPlayArtwork.glyph("music.note"))
        row.handler = { [weak self] _, completion in
            guard let self else { return completion() }
            Task {
                await self.open(item)
                completion()
            }
        }
        setCover(item.coverArt, on: row)
        return row
    }

    /// A row that opens `item`'s page, its cover laid in once it comes.
    private func row(_ item: WatchItem, placeholder: String, tint: UIColor = .white) -> CPListItem {
        let row = CPListItem(text: item.title, detailText: item.subtitle.isEmpty ? nil : item.subtitle,
                             image: CarPlayArtwork.glyph(placeholder, tint: tint), accessoryImage: nil,
                             accessoryType: .disclosureIndicator)
        row.handler = { [weak self] _, completion in
            guard let self else { return completion() }
            Task {
                await self.open(item)
                completion()
            }
        }
        setCover(item.coverArt, on: row)
        return row
    }

    private func songRow(_ song: Song, showsCover: Bool, play: @escaping () async -> Void) -> CPListItem {
        let row = CPListItem(text: song.title, detailText: song.artist,
                             image: showsCover ? CarPlayArtwork.glyph("music.note") : nil)
        row.playingIndicatorLocation = .trailing
        row.isPlaying = song.id == player.currentSong?.id
        row.handler = { _, completion in
            Task {
                await play()
                completion()
            }
        }
        if showsCover { setCover(song.coverArt, on: row) }
        songRows.setObject(song.id as NSString, forKey: row)
        return row
    }

    private func action(_ title: String, symbol: String, perform: @escaping () async -> Void) -> CPListItem {
        let row = CPListItem(text: title, detailText: nil, image: CarPlayArtwork.symbol(symbol))
        row.handler = { _, completion in
            Task {
                await perform()
                completion()
            }
        }
        return row
    }

    private func setCover(_ coverArt: String?, on row: CPListItem) {
        guard coverArt != nil else { return }
        Task { [weak row] in
            guard let image = await CarPlayArtwork.cover(coverArt) else { return }
            row?.setImage(image)
        }
    }
}
#endif
