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
                        Spacer()
                        Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                    }
                }
                .onMove { source, destination in
                    appSettings.tabOrder.move(fromOffsets: source, toOffset: destination)
                    appSettings.save()
                }
            }
        }
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
                        Text(section.rawValue)
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
        .scrollIndicators(.hidden)
        .navigationTitle("section order")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
    }
}
