import SwiftUI

// MARK: - Tab Order

struct TabOrderView: View {
    @State private var appSettings = AppSettings.shared
    private var accentColor: Color { appSettings.activeTheme.accentColor }

    var body: some View {
        List {
            Section("Drag to reorder tabs") {
                ForEach(appSettings.tabOrder) { tab in
                    HStack {
                        Image(systemName: tab.icon).foregroundStyle(accentColor).frame(width: 30)
                        Text(tab.title)
                    }
                }
                .onMove { source, destination in
                    appSettings.tabOrder.move(fromOffsets: source, toOffset: destination)
                    appSettings.save()
                }
            }
        }
        .endsAboveBottomChrome()
        .scrollIndicators(.hidden)
        .navigationTitle("tab bar order")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
    }
}

// MARK: - Home Section Order

struct HomeSectionOrderView: View {
    @State private var appSettings = AppSettings.shared
    private var accentColor: Color { appSettings.activeTheme.accentColor }

    var body: some View {
        List {
            Section("Drag to reorder home sections") {
                ForEach(appSettings.homeSectionOrder) { section in
                    HStack {
                        Image(systemName: section.icon).foregroundStyle(accentColor).frame(width: 30)
                        Text(LocalizedStringKey(section.rawValue))
                    }
                }
                .onMove { source, destination in
                    appSettings.homeSectionOrder.move(fromOffsets: source, toOffset: destination)
                    appSettings.save()
                }
            }

            Section {
                Button("Reset to Default") {
                    appSettings.homeSectionOrder = HomeSection.defaultOrder
                    appSettings.save()
                }
            }
        }
        .endsAboveBottomChrome()
        .scrollIndicators(.hidden)
        .navigationTitle("section order")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
    }
}

// MARK: - Player Buttons

/// The buttons under Now Playing's controls, in the listener's order, any of them hidden
/// (issue 10).
enum PlayerButton: String, CaseIterable, Identifiable {
    case lyrics, radio, queue, sleep, output, share
    static let key = "player_buttons"
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .lyrics: "Lyrics"
        case .radio: "Radio"
        case .queue: "Queue"
        case .sleep: "Sleep Timer"
        case .output: "Audio Output"
        case .share: "Share"
        }
    }

    var icon: String {
        switch self {
        case .lyrics: "quote.bubble"
        case .radio: "antenna.radiowaves.left.and.right"
        case .queue: "list.bullet"
        case .sleep: "moon.zzz"
        case .output: "airplayaudio"
        case .share: "square.and.arrow.up"
        }
    }

    struct Slot: Hashable { let button: PlayerButton; var shown: Bool }

    /// Stored as "lyrics,-radio,…": the order, a minus before each hidden one. A button
    /// the stored order doesn't know yet joins at the end, shown.
    static func layout(_ raw: String) -> [Slot] {
        var slots: [Slot] = []
        for part in raw.split(separator: ",") {
            let hidden = part.hasPrefix("-")
            guard let button = PlayerButton(rawValue: String(hidden ? part.dropFirst() : part)),
                  !slots.contains(where: { $0.button == button }) else { continue }
            slots.append(Slot(button: button, shown: !hidden))
        }
        return slots + allCases.filter { b in !slots.contains { $0.button == b } }.map { Slot(button: $0, shown: true) }
    }

    static func raw(_ slots: [Slot]) -> String {
        slots.map { ($0.shown ? "" : "-") + $0.button.rawValue }.joined(separator: ",")
    }
}

struct PlayerButtonsView: View {
    @AppStorage(PlayerButton.key) private var raw = ""
    @State private var appSettings = AppSettings.shared
    private var accentColor: Color { appSettings.activeTheme.accentColor }

    var body: some View {
        let slots = PlayerButton.layout(raw)
        List {
            Section {
                ForEach(slots, id: \.button) { slot in
                    Toggle(isOn: Binding(
                        get: { slot.shown },
                        set: { on in
                            raw = PlayerButton.raw(slots.map {
                                $0.button == slot.button ? PlayerButton.Slot(button: $0.button, shown: on) : $0
                            })
                        })) {
                        HStack {
                            Image(systemName: slot.button.icon).foregroundStyle(accentColor).frame(width: 30)
                            Text(slot.button.title)
                        }
                    }
                    .tint(accentColor)
                }
                .onMove { source, destination in
                    var moved = slots
                    moved.move(fromOffsets: source, toOffset: destination)
                    raw = PlayerButton.raw(moved)
                }
            } footer: {
                Text("Drag to reorder. Switch a button off to hide it from Now Playing.")
            }

            Section {
                Button("Reset to Default") { raw = "" }
            }
        }
        .endsAboveBottomChrome()
        .scrollIndicators(.hidden)
        .navigationTitle("player buttons")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
    }
}
