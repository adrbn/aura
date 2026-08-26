import Testing
import Foundation
@testable import Aura

/// Settings are persisted as a single JSON blob and read back with `try?`, so one
/// unreadable field takes every other preference down with it. Removing a typeface
/// from the app is exactly that situation: Tuaf was a trial cut and was dropped,
/// and anyone who had selected it still has "tuaf" sitting in their stored settings.
@Suite("DisplayFont")
struct DisplayFontTests {

    private struct Stored: Codable {
        let displayFont: DisplayFont?
    }

    @Test("a face that no longer exists falls back instead of failing")
    func removedFaceFallsBack() throws {
        let stored = try JSONDecoder().decode(Stored.self, from: Data(#"{"displayFont":"tuaf"}"#.utf8))
        #expect(stored.displayFont == .vavinCondensed)
    }

    @Test("an unknown face does not take the rest of the settings down with it")
    func unknownFaceDoesNotResetEverything() {
        let json = Data(#"{"displayFont":"some-face-from-a-later-build"}"#.utf8)
        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode(Stored.self, from: json)
        }
    }

    @Test("every shipping face still round-trips")
    func knownFacesRoundTrip() throws {
        for face in DisplayFont.allCases {
            let data = try JSONEncoder().encode(Stored(displayFont: face))
            let back = try JSONDecoder().decode(Stored.self, from: data)
            #expect(back.displayFont == face, "\(face.rawValue) did not survive a round-trip")
        }
    }

    @Test("no face resolves to one the text system cannot draw")
    func resolvedFaceIsAlwaysDrawable() {
        for face in DisplayFont.allCases {
            #expect(face.resolved.isAvailable, "\(face.rawValue) resolved to an unavailable face")
        }
    }

    @Test("the app's own typeface is the one that ships")
    func vavinIsTheShippingFace() {
        // Vavin is SIL OFL 1.1 and ours to redistribute; it must always be offered.
        #expect(DisplayFont.selectable.contains(.vavinCondensed))
        #expect(DisplayFont.vavinCondensed.isAvailable)
    }
}
