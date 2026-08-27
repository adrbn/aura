import Testing
import Foundation
@testable import Aura

/// Aura keeps several servers side by side, and a mix is built entirely out of one
/// server's library — its song ids, stream URLs and cover art only resolve against the
/// server they came from. The mix cache used to live under a single global key with no
/// server in it, so switching servers left the previous library's songs sitting in
/// "Made For You" long after the rest of the app had moved on: `generateIfNeeded()` saw
/// a non-empty, still-fresh cache and did nothing.
///
/// These tests pin the per-server scoping that fixes it — and the switch-back behaviour
/// that clearing the cache wholesale on every switch would have thrown away.
@Suite("Mix cache")
@MainActor
struct MixCacheTests {

    private let serverA = UUID()
    private let serverB = UUID()

    // MARK: Fixtures

    /// Every field but `id`/`title` is optional, so a minimal payload is a valid `Song`.
    private func song(_ id: String) throws -> Song {
        try JSONDecoder().decode(Song.self, from: Data(#"{"id":"\#(id)","title":"Track \#(id)"}"#.utf8))
    }

    private func mix(id: String, songIds: [String]) throws -> Mix {
        Mix(id: id, title: id.capitalized, subtitle: "", songs: try songIds.map(song))
    }

    /// A throwaway defaults suite so tests never touch the real app's stored mixes
    /// and never see each other's writes.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "MixCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    // MARK: The reported bug

    @Test("switching servers stops showing the previous server's songs")
    func mixesDoNotSurviveAServerSwitch() throws {
        try withDefaults { defaults in
            let cache = MixCache(defaults: defaults)
            cache.save([try mix(id: "now", songIds: ["a1", "a2"])], for: serverA, bucket: "morning")

            let generator = MixGenerator(defaults: defaults)
            generator.restoreForServer(serverA)
            #expect(generator.mixes.flatMap { $0.songs.map(\.id) } == ["a1", "a2"])

            // The demo server has never generated a mix — the shelf must come up empty
            // and let `generateIfNeeded()` rebuild, not keep server A's songs on screen.
            generator.restoreForServer(serverB)
            #expect(generator.mixes.isEmpty)
        }
    }

    @Test("a mix cached for one server is invisible to another")
    func cacheIsScopedPerServer() throws {
        try withDefaults { defaults in
            let cache = MixCache(defaults: defaults)
            cache.save([try mix(id: "now", songIds: ["a1"])], for: serverA, bucket: "morning")

            #expect(cache.mixes(for: serverB).isEmpty)
            #expect(cache.mixes(for: nil).isEmpty)
            #expect(cache.mixes(for: serverA).count == 1)
        }
    }

    // MARK: Multi-server: switching back must not have lost anything

    @Test("switching back finds the earlier server's mixes still there")
    func switchingBackRestoresTheEarlierServersMixes() throws {
        try withDefaults { defaults in
            let cache = MixCache(defaults: defaults)
            cache.save([try mix(id: "now", songIds: ["a1"])], for: serverA, bucket: "morning")
            cache.save([try mix(id: "now", songIds: ["b1"])], for: serverB, bucket: "morning")

            let generator = MixGenerator(defaults: defaults)
            generator.restoreForServer(serverA)
            generator.restoreForServer(serverB)
            #expect(generator.mixes.flatMap { $0.songs.map(\.id) } == ["b1"])

            generator.restoreForServer(serverA)
            #expect(generator.mixes.flatMap { $0.songs.map(\.id) } == ["a1"],
                    "server A's mixes were cleared by the switch instead of being kept alongside B's")
        }
    }

    // MARK: Freshness — the gate that let the stale mixes through

    @Test("one server's fresh cache does not make another server look fresh")
    func freshnessIsPerServer() throws {
        try withDefaults { defaults in
            let cache = MixCache(defaults: defaults)
            cache.save([try mix(id: "now", songIds: ["a1"])], for: serverA, bucket: "morning", at: Date())

            // Both of these are what `generateIfNeeded()` consults. If either leaked
            // across servers, the new server would be told its mixes were up to date.
            #expect(cache.lastGenerated(for: serverA) != nil)
            #expect(cache.lastGenerated(for: serverB) == nil)
            #expect(cache.bucket(for: serverB) == nil)
        }
    }

    // MARK: The gate that let the stale mixes through

    @Test("a server that has never generated is told to generate, however fresh its neighbour is")
    func aNeverGeneratedServerMustGenerate() throws {
        try withDefaults { defaults in
            let cache = MixCache(defaults: defaults)
            cache.save([try mix(id: "now", songIds: ["a1"])], for: serverA, bucket: "morning", at: Date())

            // This is the reported bug in one line: server A generated a minute ago, and
            // the old global cache made that answer apply to server B as well.
            #expect(cache.needsRegeneration(for: serverB, hasMixes: true, bucket: "morning"))
            #expect(!cache.needsRegeneration(for: serverA, hasMixes: true, bucket: "morning"))
        }
    }

    @Test("mixes older than eight hours are rebuilt")
    func staleMixesAreRebuilt() throws {
        try withDefaults { defaults in
            let cache = MixCache(defaults: defaults)
            let now = Date()
            cache.save([try mix(id: "now", songIds: ["a1"])], for: serverA,
                       bucket: "morning", at: now.addingTimeInterval(-9 * 3600))

            #expect(cache.needsRegeneration(for: serverA, hasMixes: true, bucket: "morning", now: now))
        }
    }

    @Test("a new part of the day rebuilds that server's mixes")
    func aChangedTimeBucketRebuilds() throws {
        try withDefaults { defaults in
            let cache = MixCache(defaults: defaults)
            cache.save([try mix(id: "now", songIds: ["a1"])], for: serverA, bucket: "morning")

            #expect(cache.needsRegeneration(for: serverA, hasMixes: true, bucket: "evening"))
            #expect(!cache.needsRegeneration(for: serverA, hasMixes: true, bucket: "morning"))
        }
    }

    @Test("an empty shelf always rebuilds")
    func anEmptyShelfRebuilds() throws {
        try withDefaults { defaults in
            let cache = MixCache(defaults: defaults)
            cache.save([try mix(id: "now", songIds: ["a1"])], for: serverA, bucket: "morning")

            #expect(cache.needsRegeneration(for: serverA, hasMixes: false, bucket: "morning"))
        }
    }

    // MARK: Saved-as-playlist tracking

    @Test("saving a mix as a playlist is recorded against its own server")
    func savedSignaturesAreScopedPerServer() throws {
        try withDefaults { defaults in
            let cache = MixCache(defaults: defaults)
            cache.setSavedSignature("sig-a", mixId: "now", for: serverA)

            #expect(cache.savedSignature(mixId: "now", for: serverA) == "sig-a")
            #expect(cache.savedSignature(mixId: "now", for: serverB) == nil)

            // Saving the same mix id on the other server must not overwrite A's record.
            cache.setSavedSignature("sig-b", mixId: "now", for: serverB)
            #expect(cache.savedSignature(mixId: "now", for: serverA) == "sig-a")
        }
    }

    // MARK: Removing a server

    @Test("removing a server takes its mixes with it")
    func removingAServerPurgesOnlyItsOwnCache() throws {
        try withDefaults { defaults in
            let cache = MixCache(defaults: defaults)
            cache.save([try mix(id: "now", songIds: ["a1"])], for: serverA, bucket: "morning")
            cache.save([try mix(id: "now", songIds: ["b1"])], for: serverB, bucket: "morning")
            cache.setSavedSignature("sig-a", mixId: "now", for: serverA)

            cache.removeAll(for: serverA)

            // Gone entirely — contents, freshness and saved-playlist record alike, the
            // same way `removeServer` already drops the server's Keychain password.
            #expect(cache.mixes(for: serverA).isEmpty)
            #expect(cache.lastGenerated(for: serverA) == nil)
            #expect(cache.bucket(for: serverA) == nil)
            #expect(cache.savedSignature(mixId: "now", for: serverA) == nil)

            // The server that was left alone keeps everything.
            #expect(cache.mixes(for: serverB).flatMap { $0.songs.map(\.id) } == ["b1"])
            #expect(cache.lastGenerated(for: serverB) != nil)
        }
    }

    // MARK: Legacy

    @Test("the old global cache is not read back under any server")
    func legacyGlobalCacheIsIgnored() throws {
        try withDefaults { defaults in
            let stale = try JSONEncoder().encode([mix(id: "now", songIds: ["old"])])
            defaults.set(stale, forKey: "musika_auto_mixes_v5")

            // Those mixes were generated against a server nobody recorded, so they
            // cannot be attributed to one now — they must simply be regenerated.
            let cache = MixCache(defaults: defaults)
            #expect(cache.mixes(for: serverA).isEmpty)
            #expect(cache.mixes(for: nil).isEmpty)
        }
    }

    @Test("the old global cache is not left behind to rot")
    func legacyGlobalCacheIsPruned() throws {
        try withDefaults { defaults in
            // A full shelf of mixes is a few hundred KB of JSON; now that nothing can
            // ever read these keys again, leaving them in place is pure dead weight.
            defaults.set(try JSONEncoder().encode([mix(id: "now", songIds: ["old"])]),
                         forKey: "musika_auto_mixes_v5")
            defaults.set(Date(), forKey: "musika_auto_mixes_date_v5")
            defaults.set("morning", forKey: "musika_auto_mixes_bucket_v5")
            defaults.set(["now": "sig"], forKey: "musika_saved_mix_signatures_v1")

            MixCache(defaults: defaults).pruneLegacyKeys()

            for key in ["musika_auto_mixes_v5", "musika_auto_mixes_date_v5",
                        "musika_auto_mixes_bucket_v5", "musika_saved_mix_signatures_v1"] {
                #expect(defaults.object(forKey: key) == nil, "\(key) survived the prune")
            }
        }
    }

    @Test("pruning does not touch the per-server caches")
    func pruningLeavesLiveCachesAlone() throws {
        try withDefaults { defaults in
            let cache = MixCache(defaults: defaults)
            cache.save([try mix(id: "now", songIds: ["a1"])], for: serverA, bucket: "morning")

            cache.pruneLegacyKeys()

            #expect(cache.mixes(for: serverA).flatMap { $0.songs.map(\.id) } == ["a1"])
        }
    }
}


/// The background style is stored inside the same single settings blob as every other
/// preference, and that blob is read back with `try?`. A style the build no longer knows
/// about therefore does not fail alone — it takes the accent colour, the appearance mode
/// and the equaliser down with it. `flat` was renamed to `plain`, so this is not
/// hypothetical: anyone who chose it has that word sitting in their stored settings.
@Suite("Background style")
struct AuraBackgroundStyleTests {

    private struct Stored: Codable {
        let backgroundStyle: AuraBackgroundStyle?
    }

    @Test("the retired 'flat' name falls back instead of failing")
    func retiredNameFallsBack() throws {
        let stored = try JSONDecoder().decode(
            Stored.self, from: Data(#"{"backgroundStyle":"flat"}"#.utf8))
        #expect(stored.backgroundStyle == .plain)
    }

    @Test("an unknown style does not take the rest of the settings down with it")
    func unknownStyleDoesNotResetEverything() {
        let json = Data(#"{"backgroundStyle":"some-style-from-a-later-build"}"#.utf8)
        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode(Stored.self, from: json)
        }
    }

    @Test("every shipping style still round-trips")
    func knownStylesRoundTrip() throws {
        for style in AuraBackgroundStyle.allCases {
            let data = try JSONEncoder().encode(Stored(backgroundStyle: style))
            let back = try JSONDecoder().decode(Stored.self, from: data)
            #expect(back.backgroundStyle == style, "\(style.rawValue) did not survive a round-trip")
        }
    }

    @Test("only the plain ground is free of the mesh")
    func onlyPlainIsFlat() {
        #expect(!AuraBackgroundStyle.plain.isMesh)
        for style in AuraBackgroundStyle.allCases where style != .plain {
            #expect(style.isMesh, "\(style.rawValue) should draw a mesh")
        }
    }
}
