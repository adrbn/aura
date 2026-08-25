import Foundation

/// Carries pinned playlists between the phone and the Mac.
///
/// iCloud's key-value store rather than a file or a CloudKit record: this is a set of
/// playlist ids and an order, it is tiny, and it wants to arrive quietly in the background
/// without either app having to be running. That is precisely what the store is for.
///
/// Conflicts are resolved last-write-wins, on a timestamp written alongside the payload.
/// Two devices pinning different playlists in the same minute is not a case worth designing
/// a merge for — and a merge would silently resurrect pins someone had just removed.
///
/// Nothing here is required for the app to work. Without the iCloud entitlement, or with
/// iCloud signed out, the store simply never reports a change and the pins stay local.
@MainActor
final class PinSync {
    static let shared = PinSync()

    private let store = NSUbiquitousKeyValueStore.default
    private static let idsKey = "aura.pinned.ids"
    private static let orderKey = "aura.pinned.order"
    private static let stampKey = "aura.pinned.stamp"

    /// Guards against the echo: applying a remote change writes to `AppSettings`, whose
    /// `save()` would otherwise push the value straight back out again.
    private var applyingRemote = false

    private init() {}

    /// Called once at launch, from each app's entry point.
    func start() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        store.synchronize()
        pull()
    }

    /// Publishes the local pins. Called whenever they change.
    func push() {
        guard !applyingRemote else { return }
        let settings = AppSettings.shared
        store.set(Array(settings.pinnedPlaylistIds), forKey: Self.idsKey)
        store.set(settings.pinnedPlaylistOrder, forKey: Self.orderKey)
        store.set(Date().timeIntervalSince1970, forKey: Self.stampKey)
        store.synchronize()
    }

    /// Adopts the remote pins when they are newer than what this device last published.
    private func pull() {
        guard let ids = store.array(forKey: Self.idsKey) as? [String] else { return }
        let remoteStamp = store.double(forKey: Self.stampKey)
        guard remoteStamp > lastLocalPush else { return }

        let order = store.array(forKey: Self.orderKey) as? [String] ?? ids
        let settings = AppSettings.shared
        // Nothing to do — and worth checking, because assigning would still trigger a save
        // and a redraw on every device every time any of them touches a pin.
        guard Set(ids) != settings.pinnedPlaylistIds || order != settings.pinnedPlaylistOrder else {
            lastLocalPush = remoteStamp
            return
        }

        applyingRemote = true
        settings.pinnedPlaylistIds = Set(ids)
        settings.pinnedPlaylistOrder = order
        settings.save()
        applyingRemote = false
        lastLocalPush = remoteStamp
    }

    /// The stamp of the last state this device accepted or published, so its own echo can
    /// be told apart from a genuinely newer change made elsewhere.
    private var lastLocalPush: Double {
        get { UserDefaults.standard.double(forKey: "aura.pinned.localStamp") }
        set { UserDefaults.standard.set(newValue, forKey: "aura.pinned.localStamp") }
    }
}
