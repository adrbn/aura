import CarPlay
import UIKit

/// The car's screen: the phone's library to browse (`CarPlayBrowser`) and the system's Now
/// Playing, set up as Aura's.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var browser: CarPlayBrowser?
    private var nowPlaying: CarPlayNowPlaying?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        AppLogger.shared.log("🚗 CarPlay connected")
        self.interfaceController = interfaceController
        let browser = CarPlayBrowser(interfaceController: interfaceController)
        self.browser = browser
        nowPlaying = CarPlayNowPlaying(browser: browser)
        interfaceController.setRootTemplate(browser.tabBar(), animated: false, completion: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        AppLogger.shared.log("🚗 CarPlay disconnected")
        nowPlaying?.stop()
        nowPlaying = nil
        browser = nil
        self.interfaceController = nil
    }
}

/// Now Playing as the car shows it: the favourite heart, shuffle and repeat below the
/// transport; Up Next opens the queue, the album button the album that's playing.
@MainActor
final class CarPlayNowPlaying: NSObject, CPNowPlayingTemplateObserver {
    private let template = CPNowPlayingTemplate.shared
    private let browser: CarPlayBrowser
    private let player = AudioPlayer.shared
    private var isStopped = false

    init(browser: CarPlayBrowser) {
        self.browser = browser
        super.init()
        template.upNextTitle = String(localized: "Up Next")
        template.add(self)
        observe()
    }

    func stop() {
        isStopped = true
        template.remove(self)
    }

    /// Follows the song, its heart and the queue, as long as the car is connected.
    private func observe() {
        guard !isStopped else { return }
        withObservationTracking {
            refresh()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func refresh() {
        let song = player.currentSong
        let symbol = song?.isStarred == true ? "heart.fill" : "heart"
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
            ?? UIImage()
        let heart = CPNowPlayingImageButton(image: image) { [weak self] _ in self?.player.toggleFavorite() }
        heart.isEnabled = song.map { !$0.isPreview } ?? false
        let shuffle = CPNowPlayingShuffleButton { [weak self] _ in self?.player.toggleShuffle() }
        let repeating = CPNowPlayingRepeatButton { [weak self] _ in self?.player.cycleRepeat() }
        template.updateNowPlayingButtons([heart, shuffle, repeating])
        template.isUpNextButtonEnabled = !player.userQueue.isEmpty || player.queueIndex + 1 < player.queue.count
        template.isAlbumArtistButtonEnabled = song?.albumId != nil
        browser.markPlaying()
    }

    // CarPlay calls its observers on the main thread.
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated { browser.showUpNext() }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated { openAlbum() }
    }

    private func openAlbum() {
        guard let song = player.currentSong, let albumId = song.albumId else { return }
        let album = WatchItem(kind: .album, id: albumId, title: song.album ?? song.title,
                              subtitle: song.artist ?? "", coverArt: song.coverArt)
        Task { await browser.open(album) }
    }
}
