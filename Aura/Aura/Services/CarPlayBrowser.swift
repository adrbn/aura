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
        let tabs = [home(), playlists(), library(), downloaded()]
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
                sections.append(CPListSection(items: albumGrid(played),
                                              header: String(localized: "Recently Played"), sectionIndexTitle: nil))
            }
            fill(template, with: sections)
        }
        return template
    }

    private func playlists() -> CPListTemplate {
        let template = tab(String(localized: "Playlists"), symbol: "music.note.list")
        fillPlaylists(template)
        playlistsTab = template
        return template
    }

    private weak var playlistsTab: CPListTemplate?
    /// Whether the playlists on screen are the ones saved for offline, the server out of reach.
    private var playlistsListedOffline = false

    /// The server's playlists — or, offline or with the server out of reach, the ones saved
    /// for offline, each reduced to the songs this iPhone holds, as the phone's offline tab.
    private func fillPlaylists(_ template: CPListTemplate) {
        Task {
            guard let server = ServerManager.shared.currentServer else { return fill(template, with: []) }
            var found: [Playlist]?
            if !player.isEffectivelyOfflineForCar {
                do {
                    found = try await SubsonicClient.shared.getPlaylists(server: server)
                } catch {
                    AppLogger.shared.log("🚗 Playlists not loaded: \(error.localizedDescription)")
                }
            }
            // The songs each saved playlist can play here; nil online, where a page asks the server.
            var available: [String: [Song]]?
            var favouriteSongs: [Song]?
            if found == nil {
                let library = OfflineLibrary.shared
                library.refresh()
                let saved = library.playlists
                found = saved.map(\.snapshot.asPlaylist)
                available = Dictionary(saved.map { ($0.snapshot.id, $0.available) }, uniquingKeysWith: { first, _ in first })
                favouriteSongs = library.favourites
            }
            playlistsListedOffline = available != nil
            let favourites = WatchItem(kind: .favorites, id: "favorites", title: String(localized: "Favorites"),
                                       subtitle: String(localized: "Your starred songs"), coverArt: nil)
            var pinned = [row(favourites, placeholder: "heart.fill", tint: CarPlayArtwork.accent, songs: favouriteSongs)]
            let settings = AppSettings.shared
            let playlistRow = { (playlist: Playlist) in
                self.row(LibraryCatalog.item(playlist), placeholder: "music.note.list", songs: available?[playlist.id])
            }
            let all = found ?? []
            pinned += Self.pinnedFirst(all.filter { settings.isPinned($0.id) }).map(playlistRow)
            let others = all.filter { !settings.isPinned($0.id) }
                .sorted { ($0.changed ?? "") > ($1.changed ?? "") }
                .map(playlistRow)
            fill(template, with: [CPListSection(items: pinned), CPListSection(items: others)])
        }
    }

    private func library() -> CPListTemplate {
        let template = tab(String(localized: "Library"), symbol: "square.stack.fill")
        let shuffle = action(String(localized: "Shuffle Library"), symbol: "shuffle") { [weak self] in
            await self?.shuffleLibrary()
        }
        let artists = action(String(localized: "Artists"), symbol: "music.mic") { [weak self] in
            await self?.showArtists()
        }
        let radio = action(String(localized: "Radio"), symbol: "antenna.radiowaves.left.and.right") { [weak self] in
            await self?.showRadio()
        }
        template.updateSections([CPListSection(items: [shuffle, artists, radio])])
        Task {
            let newest = await albums("newest", count: 24)
            guard !newest.isEmpty else { return }
            fill(template, with: [
                CPListSection(items: [shuffle, artists, radio]),
                CPListSection(items: albumGrid(newest),
                              header: String(localized: "Recently Added"), sectionIndexTitle: nil),
            ])
        }
        return template
    }

    /// What this iPhone holds, for the road where the network drops: a shuffle of it all,
    /// then its albums, newest first. Read again each time the tab is shown.
    private func downloaded() -> CPListTemplate {
        let template = tab(String(localized: "Downloaded"), symbol: "arrow.down.circle.fill")
        fillDownloaded(template)
        downloadedTab = template
        return template
    }

    private weak var downloadedTab: CPListTemplate?

    /// Called when the car shows a tab: the downloads may have grown since, and the playlists
    /// listed online are no use offline — nor the saved ones once the server is back.
    func refreshIfShown(_ template: CPTemplate) {
        if let tab = downloadedTab, template === tab { fillDownloaded(tab) }
        if let tab = playlistsTab, template === tab, playlistsListedOffline != player.isEffectivelyOfflineForCar {
            fillPlaylists(tab)
        }
    }

    private func fillDownloaded(_ template: CPListTemplate) {
        let library = OfflineLibrary.shared
        library.refresh()
        let songs = library.songs
        guard !songs.isEmpty else {
            template.updateSections([])
            template.emptyViewTitleVariants = [String(localized: "Download music on your iPhone to play it here without a connection")]
            return
        }
        let shuffle = action(String(localized: "Shuffle Downloaded"), symbol: "shuffle") { [weak self] in
            let item = WatchItem(kind: .mix, id: "downloaded", title: String(localized: "Downloaded"),
                                 subtitle: "", coverArt: nil)
            await self?.play(songs, of: item, at: 0, shuffled: true)
        }
        let albums = library.recentAlbums.map { album -> CPListItem in
            let item = WatchItem(kind: .album, id: album.id, title: album.name, subtitle: album.artist,
                                 coverArt: album.coverArt)
            let row = CPListItem(text: album.name, detailText: album.artist,
                                 image: CarPlayArtwork.glyph("square.stack"), accessoryImage: nil,
                                 accessoryType: .disclosureIndicator)
            row.handler = { [weak self] _, completion in
                guard let self else { return completion() }
                Task {
                    await self.open(item, songs: album.songs)
                    completion()
                }
            }
            setCover(album.coverArt, on: row)
            return row
        }
        fill(template, with: [
            CPListSection(items: [shuffle]),
            CPListSection(items: albums, header: String(localized: "Albums"), sectionIndexTitle: nil),
        ])
    }

    /// Every artist, A to Z under their letters, the letters down the side to jump by. A
    /// library larger than a list can hold — each row fetches its picture — goes by its
    /// letters first: a list of them, each opening its own artists.
    private func showArtists() async {
        guard let server = ServerManager.shared.currentServer else { return }
        let all: [Artist]
        do {
            all = try await SubsonicClient.shared.getArtists(server: server)
        } catch {
            AppLogger.shared.log("🚗 Artists not loaded: \(error.localizedDescription)")
            return
        }
        let sorted = all.sorted { $0.sortKey.localizedCaseInsensitiveCompare($1.sortKey) == .orderedAscending }
        // Grouping keeps the A to Z order inside each letter; "#" goes last, as on the phone.
        let letters = Dictionary(grouping: sorted, by: Self.indexLetter).sorted { lhs, rhs in
            if (lhs.key == "#") != (rhs.key == "#") { return rhs.key == "#" }
            return lhs.key < rhs.key
        }
        let template = CPListTemplate(title: String(localized: "Artists"), sections: [])
        if sorted.count <= Self.rowLimit, letters.count <= Int(CPListTemplate.maximumSectionCount) {
            fill(template, with: letters.map { letter, artists in
                CPListSection(items: artists.map { row(LibraryCatalog.item($0), placeholder: "music.mic") },
                              header: letter, sectionIndexTitle: letter)
            })
        } else {
            let rows = letters.map { letter, artists in
                let row = CPListItem(text: letter, detailText: nil, image: nil, accessoryImage: nil,
                                     accessoryType: .disclosureIndicator)
                row.handler = { [weak self] _, completion in
                    self?.pushArtists(artists, title: letter)
                    completion()
                }
                return row
            }
            fill(template, with: [CPListSection(items: rows)])
        }
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// One letter's artists.
    private func pushArtists(_ artists: [Artist], title: String) {
        // ponytail: a letter past the row limit shows its first names only; split by second
        // letter if a library ever has that many under one.
        let rows = artists.prefix(Self.rowLimit).map { row(LibraryCatalog.item($0), placeholder: "music.mic") }
        let template = CPListTemplate(title: title, sections: [])
        fill(template, with: [CPListSection(items: rows)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// The letter an artist is filed under: the first of their sort name, accents dropped,
    /// "#" for a digit or a sign. The car takes one character per index title.
    private static func indexLetter(_ artist: Artist) -> String {
        guard let first = artist.sortKey.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).first,
              first.isLetter else { return "#" }
        return String(first.uppercased().prefix(1))
    }

    /// The server's internet radio stations; a tap plays the station.
    private func showRadio() async {
        guard let server = ServerManager.shared.currentServer else { return }
        let stations: [InternetRadioStation]
        do {
            stations = try await SubsonicClient.shared.getInternetRadioStations(server: server)
        } catch {
            AppLogger.shared.log("🚗 Radio stations not loaded: \(error.localizedDescription)")
            return
        }
        let rows = stations.map { station in
            action(station.name, symbol: "antenna.radiowaves.left.and.right") { [weak self] in
                self?.play(station)
            }
        }
        let template = CPListTemplate(title: String(localized: "Radio"), sections: [])
        fill(template, with: [CPListSection(items: rows)])
        template.emptyViewTitleVariants = [String(localized: "No radio stations on your server")]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// A station plays as a radar preview does, straight from its address: nothing about it
    /// can be asked of the server or told to it — no star, no scrobble, no queue around it.
    private func play(_ station: InternetRadioStation) {
        guard URL(string: station.streamUrl) != nil else { return }
        let song = Song(id: "radio-\(station.id)", title: station.name, album: nil, artist: nil, albumId: nil,
                        artistId: nil, artists: nil, track: nil, year: nil, genre: nil, coverArt: nil,
                        duration: nil, bitRate: nil, suffix: nil, contentType: nil, isDir: false, starred: nil,
                        size: nil, path: nil, playCount: nil, mediaType: nil, explicit: nil, created: nil,
                        replayGain: nil, preview: station.streamUrl)
        player.playSong(song, fromQueue: [song])
        showNowPlaying()
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
            return CPListSection(items: items, header: section.header, sectionIndexTitle: section.sectionIndexTitle)
        }
        template.emptyViewTitleVariants = [ServerManager.shared.currentServer == nil
            ? String(localized: "Sign in to Aura on your iPhone")
            : !ServerManager.shared.hasNetwork
            ? String(localized: "No connection — your downloads are in Downloaded")
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
        let row = Self.imageRow(images: covers)
        row.listImageRowHandler = { [weak self] _, index, completion in
            guard let self, mixes.indices.contains(index) else { return completion() }
            let cover = covers.indices.contains(index) ? covers[index] : nil
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
            Self.update(row, with: photos)
        }
        return row
    }

    /// Covers without captions: iOS 26's elements, the older image grid before that.
    private static func imageRow(images: [UIImage]) -> CPListImageRowItem {
        if #available(iOS 26.0, *) {
            CPListImageRowItem(text: nil, elements: elements(images), allowsMultipleLines: true)
        } else {
            CPListImageRowItem(text: "", images: images)
        }
    }

    @available(iOS 26.0, *)
    private static func elements(_ covers: [UIImage]) -> [CPListImageRowItemRowElement] {
        covers.map { CPListImageRowItemRowElement(image: $0, title: nil, subtitle: nil) }
    }

    private static func update(_ row: CPListImageRowItem?, with images: [UIImage]) {
        guard let row else { return }
        if #available(iOS 26.0, *) {
            row.elements = elements(images)
        } else {
            row.update(images)
        }
    }

    /// Albums as rows of covers, the name and artist under each, as the phone's grids show
    /// them: a placeholder at once, the covers laid in as they come. A tap opens the album —
    /// a single plays straight away.
    private func albumGrid(_ albums: [Album]) -> [CPListImageRowItem] {
        let perRow = Int(CPMaximumNumberOfGridImages)
        let placeholder = CarPlayArtwork.glyph("square.stack")
        return stride(from: 0, to: albums.count, by: perRow).map { start in
            let chunk = Array(albums[start..<min(start + perRow, albums.count)])
            let images = chunk.map { _ in placeholder }
            let titles = chunk.map(\.name)
            let subtitles = chunk.map(\.artist)
            let row = Self.imageRow(images: images, titles: titles, subtitles: subtitles)
            row.listImageRowHandler = { [weak self] _, index, completion in
                guard let self, chunk.indices.contains(index) else { return completion() }
                let cover = images[index] === placeholder ? nil : images[index]
                Task {
                    await self.open(LibraryCatalog.item(chunk[index]), cover: cover)
                    completion()
                }
            }
            Task { [weak row] in
                var photos: [UIImage] = []
                for album in chunk {
                    photos.append(await CarPlayArtwork.cover(album.coverArt) ?? placeholder)
                }
                Self.update(row, with: photos, titles: titles, subtitles: subtitles)
            }
            return row
        }
    }

    /// Albums as a grid of covers, with their names underneath. iOS 18 has one line of
    /// caption per image, so the artist rides along in the name there.
    private static func imageRow(images: [UIImage], titles: [String], subtitles: [String]) -> CPListImageRowItem {
        if #available(iOS 26.0, *) {
            CPListImageRowItem(text: nil, elements: elements(images: images, titles: titles, subtitles: subtitles),
                               allowsMultipleLines: true)
        } else {
            CPListImageRowItem(text: "", images: images,
                               imageTitles: zip(titles, subtitles).map { "\($0.0) — \($0.1)" })
        }
    }

    @available(iOS 26.0, *)
    private static func elements(images: [UIImage], titles: [String], subtitles: [String]) -> [CPListImageRowItemRowElement] {
        images.indices.map { index in
            CPListImageRowItemRowElement(image: images[index], title: titles[index], subtitle: subtitles[index])
        }
    }

    private static func update(_ row: CPListImageRowItem?, with images: [UIImage],
                               titles: [String], subtitles: [String]) {
        guard let row else { return }
        if #available(iOS 26.0, *) {
            row.elements = elements(images: images, titles: titles, subtitles: subtitles)
        } else {
            row.update(images)
        }
    }

    // MARK: - Detail

    /// A mix, a playlist, the favourites or an album, as its page on the phone: Play and
    /// Shuffle, then its songs. From iOS 26.4 the cover heads the page, Play and Shuffle
    /// under it as Apple Music has them; before, they are its first two rows.
    func open(_ item: WatchItem, cover: UIImage? = nil, songs given: [Song]? = nil) async {
        var songs = given ?? []
        if given == nil { songs = await LibraryCatalog.songs(of: item) }
        // One song has no page to browse: it plays.
        if songs.count == 1 { return await play(songs, of: item, at: 0, shuffled: false) }
        // Under a header the name is already there, large: the bar above goes without it.
        var headed = false
        if #available(iOS 26.4, *) { headed = !songs.isEmpty }
        let template = CPListTemplate(title: headed ? nil : item.title, sections: [])
        template.emptyViewTitleVariants = [String(localized: "Nothing to play")]
        if !songs.isEmpty {
            let playAll: () async -> Void = { [weak self] in
                await self?.play(songs, of: item, at: 0, shuffled: false)
            }
            let shuffleAll: () async -> Void = { [weak self] in
                await self?.play(songs, of: item, at: 0, shuffled: true)
            }
            // Every song on an album shares its cover: the rows go without.
            // An artist's page: their top songs, then their albums.
            let songLimit = item.kind == .artist ? 10 : max(0, Self.rowLimit - 2)
            let rows = songs.prefix(songLimit).enumerated().map { index, song in
                songRow(song, showsCover: item.kind != .album) { [weak self] in
                    await self?.play(songs, of: item, at: index, shuffled: false)
                }
            }
            var sections = [CPListSection(items: rows)]
            if item.kind == .artist, let server = ServerManager.shared.currentServer,
               let albums = try? await SubsonicClient.shared.getArtist(server: server, id: item.id).album,
               !albums.isEmpty {
                sections = [CPListSection(items: rows, header: String(localized: "Top Songs"), sectionIndexTitle: nil),
                            CPListSection(items: albumGrid(Array(albums.prefix(Self.rowLimit - 12))),
                                          header: String(localized: "Albums"), sectionIndexTitle: nil)]
            }
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
        let actions = [play, shuffle]
        // Plain SF Symbols the car draws itself, crisp at its own scale: a picture of icon plus
        // text came out blurry and faint on car screens.
        let symbols = ["play.fill", "shuffle"]
        let buttons = zip(symbols, actions).map { symbol, perform in
            CPButton(image: UIImage(systemName: symbol) ?? UIImage()) { _ in Task { await perform() } }
        }
        // A mix's or playlist's line is a description: it reads whole in the body, where the
        // subtitle would cut it to one line.
        let describes = item.kind == .mix || item.kind == .playlist
        let header = CPListTemplateDetailsHeader(thumbnail: CPThumbnailImage(image: thumbnail), title: item.title,
                                                 subtitle: describes || item.subtitle.isEmpty ? nil : item.subtitle,
                                                 actionButtons: buttons)
        if describes, !item.subtitle.isEmpty {
            header.bodyVariants = [NSAttributedString(string: item.subtitle)]
        }
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

    /// A row that opens `item`'s page, its cover laid in once it comes. `songs`, when given,
    /// are what the page lists instead of asking the server — the offline playlists'.
    private func row(_ item: WatchItem, placeholder: String, tint: UIColor = .white, songs: [Song]? = nil) -> CPListItem {
        let row = CPListItem(text: item.title, detailText: item.subtitle.isEmpty ? nil : item.subtitle,
                             image: CarPlayArtwork.glyph(placeholder, tint: tint), accessoryImage: nil,
                             accessoryType: .disclosureIndicator)
        row.handler = { [weak self] _, completion in
            guard let self else { return completion() }
            Task {
                await self.open(item, songs: songs)
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
