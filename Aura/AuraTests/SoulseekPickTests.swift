import Testing
import Foundation
@testable import Aura

/// Choosing a Soulseek folder for a release without asking: which folder holds it, which file
/// is which track, and which peer gets the download.
@Suite("Soulseek pick")
struct SoulseekPickTests {

    // MARK: Fixtures

    private let album = [
        SoulseekPick.Track(id: 1, title: "Sun King", seconds: 200, position: 1),
        SoulseekPick.Track(id: 2, title: "Olalla", seconds: 180, position: 2),
        SoulseekPick.Track(id: 3, title: "The Wind (feat. Lucy)", seconds: 240, position: 3),
        SoulseekPick.Track(id: 4, title: "Desert Air", seconds: 210, position: 4),
    ]

    private func file(_ path: String, seconds: Int?, bitRate: Int? = nil, size: Int64 = 30_000_000,
                      locked: Bool = false) -> SlskdFile {
        SlskdFile(filename: path, size: size, bitRate: bitRate, length: seconds, code: nil, isLocked: locked)
    }

    private func peer(_ name: String, _ files: [SlskdFile], free: Bool = true, speed: Int = 2_000_000,
                      queue: Int = 0) -> SlskdSearchResponse {
        SlskdSearchResponse(username: name, fileCount: files.count, lockedFileCount: 0, uploadSpeed: speed,
                            hasFreeUploadSlot: free, queueLength: queue, files: files, lockedFiles: nil)
    }

    private func folder(_ dir: String, ext: String = "flac", bitRate: Int? = nil,
                        tracks: [SoulseekPick.Track]? = nil) -> [SlskdFile] {
        (tracks ?? album).map { track in
            let title = SongQuery.cleanTitle(track.title)
            return file("@@music\\\(dir)\\0\(track.position ?? 0) - \(title).\(ext)",
                        seconds: track.seconds, bitRate: bitRate)
        }
    }

    private func pick(_ responses: [SlskdSearchResponse], tracks: [SoulseekPick.Track]? = nil)
        -> [SoulseekPick.Candidate] {
        SoulseekPick.candidates(for: tracks ?? album, artist: "Blanco White", album: "Tarifa",
                                in: responses)
    }

    // MARK: Folders

    @Test func theWholeAlbumBeatsPartOfIt() {
        let whole = peer("whole", folder("Blanco White - Tarifa (2026)", ext: "mp3", bitRate: 320))
        let part = peer("part", Array(folder("Blanco White - Tarifa").prefix(3)))
        let picked = pick([part, whole])
        #expect(picked.first?.username == "whole")
        #expect(picked.first?.files.count == 4)
    }

    @Test func tooLittleOfTheAlbumIsNoCandidate() {
        let half = peer("half", Array(folder("Blanco White - Tarifa").prefix(2)))
        #expect(pick([half]).isEmpty)
        #expect(SoulseekPick.required(of: 4) == 3)
        #expect(SoulseekPick.required(of: 1) == 1)
        #expect(SoulseekPick.required(of: 10) == 8)
    }

    @Test func aFolderWithoutTheArtistIsSomeoneElses() {
        let other = peer("other", folder("Various - Summer Hits"))
        #expect(pick([other]).isEmpty)
    }

    @Test func lockedFilesAreNotOnOffer() {
        let locked = folder("Blanco White - Tarifa").map {
            file($0.filename, seconds: $0.length, locked: true)
        }
        #expect(pick([peer("locked", locked)]).isEmpty)
    }

    // MARK: Tracks

    @Test func anotherVersionIsNotTheTrack() {
        let single = [SoulseekPick.Track(id: 9, title: "Sun King", seconds: 200, position: 1)]
        let files = [
            file("@@a\\Blanco White\\Sun King (Instrumental).flac", seconds: 200),
            file("@@a\\Blanco White\\Sun King (Live).flac", seconds: 200),
        ]
        #expect(pick([peer("versions", files)], tracks: single).isEmpty)
    }

    @Test func aRemixTitleTakesTheRemix() {
        let remix = [SoulseekPick.Track(id: 9, title: "Sun King (Kygo Remix)", seconds: 230, position: 1)]
        let files = [
            file("@@a\\Blanco White\\01 Sun King.flac", seconds: 200),
            file("@@a\\Blanco White\\02 Sun King (Kygo Remix).flac", seconds: 230),
        ]
        let picked = pick([peer("remix", files)], tracks: remix)
        #expect(picked.first?.files[9]?.filename.contains("Remix") == true)
    }

    @Test func anotherLengthIsAnotherCut() {
        let single = [SoulseekPick.Track(id: 9, title: "Sun King", seconds: 200, position: 1)]
        let edit = [file("@@a\\Blanco White\\Sun King.mp3", seconds: 320, bitRate: 320)]
        #expect(pick([peer("edit", edit)], tracks: single).isEmpty)
        let same = [file("@@a\\Blanco White\\Sun King.mp3", seconds: 203, bitRate: 320)]
        #expect(pick([peer("same", same)], tracks: single).count == 1)
    }

    @Test func featuredArtistsNeedNotBeInTheName() {
        let picked = pick([peer("p", folder("Blanco White - Tarifa"))])
        #expect(picked.first?.files[3]?.filename.hasSuffix("The Wind.flac") == true)
    }

    // MARK: Peers

    @Test func aFreeSlotBeatsAQueue() {
        let queued = peer("queued", folder("Blanco White - Tarifa"), free: false, queue: 40)
        let free = peer("free", folder("Blanco White - Tarifa"))
        #expect(pick([queued, free]).first?.username == "free")
    }

    @Test func losslessWinsAtTheSameSpeed() {
        let mp3 = peer("mp3", folder("Blanco White - Tarifa", ext: "mp3", bitRate: 320))
        let flac = peer("flac", folder("Blanco White - Tarifa"))
        #expect(pick([mp3, flac]).first?.username == "flac")
    }

    // MARK: Files

    @Test func qualityGrades() {
        #expect(SoulseekPick.quality(of: file("a.flac", seconds: 1)) == .lossless)
        #expect(SoulseekPick.quality(of: file("a.mp3", seconds: 1, bitRate: 320)) == .high)
        #expect(SoulseekPick.quality(of: file("a.mp3", seconds: 1, bitRate: 256)) == .good)
        #expect(SoulseekPick.quality(of: file("a.mp3", seconds: 1, bitRate: 128)) == nil)
        #expect(SoulseekPick.quality(of: file("a.m4a", seconds: 1, bitRate: 900)) == .lossless)
        #expect(SoulseekPick.quality(of: file("a.wav", seconds: 1)) == nil)
    }

    @Test func trackNumbers() {
        #expect(SoulseekPick.leadingNumber("03 - Title") == 3)
        #expect(SoulseekPick.leadingNumber("1-03 Title") == 3)
        #expect(SoulseekPick.leadingNumber("03. Title") == 3)
        #expect(SoulseekPick.leadingNumber("2024 - Title") == nil)
        #expect(SoulseekPick.leadingNumber("Title") == nil)
    }

    @Test func queriesDropBracketsAndTryWithoutAccents() {
        let queries = SoulseekPick.queries(artist: "Zaoui", title: "Karaté Cœur (Deluxe)")
        #expect(queries.first == "Zaoui Karaté Cœur")
        #expect(queries.contains("zaoui karate coeur"))
        #expect(queries.contains("karate coeur"))
    }
}
