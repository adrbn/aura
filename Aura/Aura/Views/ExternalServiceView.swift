import SwiftUI

#if !APPSTORE_BUILD

struct ExternalServiceView: View {
    @State private var selectedTab = 0
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("Search").tag(0)
                Text("Downloads").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ZStack {
                SlskdSearchView()
                    .opacity(selectedTab == 0 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 0)
                SlskdDownloadsView(isVisible: selectedTab == 1)
                    .opacity(selectedTab == 1 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 1)
            }
        }
        .navigationTitle("slskd")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Native slskd Search View

struct SlskdSearchView: View {
    @Environment(\.appAccentColor) private var accentColor
    @State private var searchQuery = ""
    @State private var isSearching = false
    @State private var searchId: String?
    @State private var results: [SlskdSearchResponse] = []
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var cleanupTask: Task<Void, Never>?
    @State private var searchStatus: String?
    @State private var downloadingFiles: Set<String> = []
    @State private var enqueuedFiles: Set<String> = []
    @State private var failedFiles: Set<String> = []
    @State private var filterAudioOnly = true
    @State private var selectedFormats: Set<String> = []
    @State private var selectedBitrates: Set<Int> = []
    @State private var sortBy: SortOption = .quality
    @State private var searchHistory: [String] = UserDefaults.standard.stringArray(forKey: "slskd_search_history") ?? []

    private let allFormats = ["FLAC", "MP3", "OGG", "OPUS", "M4A", "AAC", "WAV"]
    private let allBitrates = [128, 192, 256, 320, 500]

    enum SortOption: String, CaseIterable {
        case quality = "Quality"
        case bitRate = "Bitrate"
        case size = "Size"
        case speed = "Speed"

        var icon: String {
            switch self {
            case .quality: return "star.fill"
            case .bitRate: return "waveform"
            case .size: return "arrow.up.arrow.down"
            case .speed: return "bolt.fill"
            }
        }
    }

    /// All audio files from results, flattened and sorted
    private var filteredFiles: [(file: SlskdFile, username: String, speed: Int, hasFreeSlot: Bool)] {
        var items: [(file: SlskdFile, username: String, speed: Int, hasFreeSlot: Bool)] = []

        for response in results {
            let speed = response.uploadSpeed ?? 0
            let freeSlot = response.hasFreeUploadSlot ?? false
            let allFiles = response.files + (response.lockedFiles ?? [])
            for file in allFiles {
                if filterAudioOnly && !file.isAudio { continue }
                if !selectedFormats.isEmpty && !selectedFormats.contains(file.fileExtension) { continue }
                if !selectedBitrates.isEmpty {
                    let br = file.bitRate ?? 0
                    let minBr = selectedBitrates.min() ?? 0
                    if br < minBr { continue }
                }
                items.append((file: file, username: response.username, speed: speed, hasFreeSlot: freeSlot))
            }
        }

        switch sortBy {
        case .quality:
            // Lossless first, then by bitrate, then by free slot + speed
            items.sort { a, b in
                let aLossless = ["FLAC", "WAV", "ALAC", "APE", "WV"].contains(a.file.fileExtension)
                let bLossless = ["FLAC", "WAV", "ALAC", "APE", "WV"].contains(b.file.fileExtension)
                if aLossless != bLossless { return aLossless }
                let aBr = a.file.bitRate ?? 0
                let bBr = b.file.bitRate ?? 0
                if aBr != bBr { return aBr > bBr }
                if a.hasFreeSlot != b.hasFreeSlot { return a.hasFreeSlot }
                return a.speed > b.speed
            }
        case .bitRate:
            items.sort { ($0.file.bitRate ?? 0) > ($1.file.bitRate ?? 0) }
        case .size:
            items.sort { $0.file.size > $1.file.size }
        case .speed:
            items.sort { $0.speed > $1.speed }
        }

        return items
    }

    var body: some View {
        List {
            // Search bar
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Soulseek...", text: $searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { startSearch() }
                    if isSearching {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if !searchQuery.isEmpty {
                        Button {
                            startSearch()
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(accentColor)
                        }
                    }
                }
            }

            // Search history (shown when no results and not searching)
            if results.isEmpty && !isSearching && !searchHistory.isEmpty {
                Section {
                    ForEach(searchHistory, id: \.self) { query in
                        Button {
                            searchQuery = query
                            startSearch()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(query)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Button {
                                    removeFromHistory(query)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        if searchHistory.count > 1 {
                            Button("Clear") { clearHistory() }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Status
            if let status = searchStatus {
                Section {
                    HStack(spacing: 8) {
                        if isSearching {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            // Filter pills bar
            if !results.isEmpty {
                Section {
                    HStack(spacing: 6) {
                        // Audio Only toggle
                        filterPill(
                            label: "Audio",
                            icon: nil,
                            isActive: filterAudioOnly,
                            color: .cyan
                        ) { filterAudioOnly.toggle() }

                        // Format menu
                        Menu {
                            Button {
                                selectedFormats = []
                            } label: {
                                HStack {
                                    Text("All")
                                    if selectedFormats.isEmpty { Image(systemName: "checkmark") }
                                }
                            }
                            Divider()
                            ForEach(allFormats, id: \.self) { fmt in
                                Button {
                                    if selectedFormats.contains(fmt) {
                                        selectedFormats.remove(fmt)
                                    } else {
                                        selectedFormats.insert(fmt)
                                    }
                                } label: {
                                    HStack {
                                        Text(fmt)
                                        if selectedFormats.contains(fmt) { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            filterPillLabel(
                                label: formatPillText,
                                icon: nil,
                                isActive: !selectedFormats.isEmpty,
                                color: .purple
                            )
                        }

                        // Bitrate menu
                        Menu {
                            Button {
                                selectedBitrates = []
                            } label: {
                                HStack {
                                    Text("Any")
                                    if selectedBitrates.isEmpty { Image(systemName: "checkmark") }
                                }
                            }
                            Divider()
                            ForEach(allBitrates, id: \.self) { br in
                                Button {
                                    if selectedBitrates.contains(br) {
                                        selectedBitrates.remove(br)
                                    } else {
                                        selectedBitrates = [br]
                                    }
                                } label: {
                                    HStack {
                                        Text(br >= 500 ? "Lossless" : "\(br)+")
                                        if selectedBitrates.contains(br) { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            filterPillLabel(
                                label: bitratePillText,
                                icon: nil,
                                isActive: !selectedBitrates.isEmpty,
                                color: .green
                            )
                        }

                        // Sort menu
                        Menu {
                            ForEach(SortOption.allCases, id: \.self) { opt in
                                Button {
                                    sortBy = opt
                                } label: {
                                    HStack {
                                        Image(systemName: opt.icon)
                                        Text(opt.rawValue)
                                        if sortBy == opt { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            filterPillLabel(
                                label: sortBy.rawValue,
                                icon: sortBy.icon,
                                isActive: true,
                                color: .orange
                            )
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }

            // Results
            if !filteredFiles.isEmpty {
                Section {
                    ForEach(Array(filteredFiles.prefix(200).enumerated()), id: \.offset) { _, item in
                        SlskdFileRow(
                            file: item.file,
                            username: item.username,
                            speed: item.speed,
                            isDownloading: downloadingFiles.contains(item.file.filename),
                            isEnqueued: enqueuedFiles.contains(item.file.filename),
                            isFailed: failedFiles.contains(item.file.filename),
                            onDownload: { downloadFile(item.file, from: item.username) }
                        )
                    }
                } header: {
                    Text("\(filteredFiles.count) results")
                }
            }

            // Bottom spacer for miniplayer
            Section { EmptyView() }
                .listRowBackground(Color.clear)
                .frame(height: 80)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Filter Pills

    private var formatPillText: String {
        guard let first = selectedFormats.first else { return "Format" }
        if selectedFormats.count == 1 { return first }
        if selectedFormats.count == 2 {
            let sorted = selectedFormats.sorted()
            return "\(sorted[0])+\(sorted[1])"
        }
        return "\(selectedFormats.count) fmts"
    }

    private var bitratePillText: String {
        guard let br = selectedBitrates.first else { return "kbps" }
        return br >= 500 ? "Lossless" : "\(br)+"
    }

    private func filterPill(label: String, icon: String?, isActive: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            filterPillLabel(label: label, icon: icon, isActive: isActive, color: color)
        }
        .buttonStyle(.plain)
    }

    private func filterPillLabel(label: String, icon: String?, isActive: Bool, color: Color) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
            }
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isActive ? color.opacity(0.2) : Color(.systemGray5))
        .foregroundStyle(isActive ? color : .secondary)
        .clipShape(Capsule())
    }

    // MARK: - Search History

    private func addToHistory(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        var history = searchHistory
        history.removeAll { $0.lowercased() == q.lowercased() }
        history.insert(q, at: 0)
        if history.count > 15 { history = Array(history.prefix(15)) }
        searchHistory = history
        UserDefaults.standard.set(history, forKey: "slskd_search_history")
    }

    private func removeFromHistory(_ query: String) {
        searchHistory.removeAll { $0 == query }
        UserDefaults.standard.set(searchHistory, forKey: "slskd_search_history")
    }

    private func clearHistory() {
        searchHistory = []
        UserDefaults.standard.removeObject(forKey: "slskd_search_history")
    }

    private func startSearch() {
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        addToHistory(searchQuery)
        pollTask?.cancel()
        cleanupTask?.cancel()
        results = []
        error = nil
        isSearching = true
        searchStatus = "Searching..."
        downloadingFiles = []
        enqueuedFiles = []
        failedFiles = []

        pollTask = Task {
            do {
                let search = try await SlskdClient.shared.search(query: searchQuery)
                searchId = search.id

                // Poll for results
                for i in 0..<20 {
                    try await Task.sleep(for: .seconds(i < 5 ? 1.0 : 2.0))
                    if Task.isCancelled { return }

                    let status = try await SlskdClient.shared.getSearch(id: search.id)
                    let responses = try await SlskdClient.shared.getSearchResponses(id: search.id)

                    await MainActor.run {
                        results = responses
                        searchStatus = "\(status.fileCount) files from \(status.responseCount) users"
                    }

                    if status.isFinished { break }
                }

                await MainActor.run {
                    isSearching = false
                    scheduleCleanup(searchId: search.id)
                }
            } catch is CancellationError {
                // Ignore — a new search replaced this one
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.error = error.localizedDescription
                    isSearching = false
                    searchStatus = nil
                }
            }
        }
    }

    /// Clean up the slskd search after 5 minutes
    private func scheduleCleanup(searchId: String) {
        cleanupTask?.cancel()
        cleanupTask = Task {
            try? await Task.sleep(for: .seconds(300)) // 5 minutes
            if Task.isCancelled { return }
            try? await SlskdClient.shared.deleteSearch(id: searchId)
        }
    }

    private func downloadFile(_ file: SlskdFile, from username: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        downloadingFiles.insert(file.filename)
        failedFiles.remove(file.filename)

        Task {
            do {
                let req = SlskdDownloadRequest(filename: file.filename, size: file.size)
                let response = try await SlskdClient.shared.download(username: username, files: [req])

                await MainActor.run {
                    downloadingFiles.remove(file.filename)
                    if let failed = response.failed, !failed.isEmpty {
                        failedFiles.insert(file.filename)
                    } else {
                        enqueuedFiles.insert(file.filename)
                    }
                }
            } catch {
                await MainActor.run {
                    downloadingFiles.remove(file.filename)
                    failedFiles.insert(file.filename)
                }
            }
        }
    }
}

// MARK: - File Row

struct SlskdFileRow: View {
    let file: SlskdFile
    let username: String
    let speed: Int
    let isDownloading: Bool
    let isEnqueued: Bool
    let isFailed: Bool
    let onDownload: () -> Void

    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        HStack(spacing: 12) {
            // File type badge
            Text(file.fileExtension)
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(badgeColor.opacity(0.15))
                .foregroundStyle(badgeColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: 44)

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(file.displayName)
                    .font(.subheadline)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(file.displaySize)
                    if let br = file.bitRate, br > 0 {
                        Text("·")
                        Text("\(br)kbps")
                    }
                    if let dur = file.displayDuration {
                        Text("·")
                        Text(dur)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: "person")
                    Text(username)
                    if speed > 0 {
                        Text("·")
                        Text(formatSpeed(speed))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            // Download button
            Button(action: onDownload) {
                Group {
                    if isDownloading {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else if isEnqueued {
                        Image(systemName: "arrow.down.circle.dotted")
                            .foregroundStyle(.yellow)
                    } else if isFailed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(accentColor)
                    }
                }
                .frame(width: 32, height: 32)
            }
            .disabled(isDownloading || isEnqueued)
        }
        .padding(.vertical, 2)
    }

    private var badgeColor: Color {
        switch file.fileExtension {
        case "FLAC": return .blue
        case "MP3": return .orange
        case "OGG", "OPUS": return .purple
        case "M4A", "AAC": return .green
        case "WAV": return .cyan
        default: return .gray
        }
    }

    private func formatSpeed(_ bytesPerSec: Int) -> String {
        let kbps = bytesPerSec / 1024
        if kbps >= 1024 {
            return String(format: "%.1f MB/s", Double(kbps) / 1024.0)
        }
        return "\(kbps) KB/s"
    }
}

// MARK: - Downloads View

struct SlskdDownloadsView: View {
    let isVisible: Bool
    @Environment(\.appAccentColor) private var accentColor
    @State private var transfers: [FlatTransfer] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var deletingIds: Set<String> = []
    @State private var pollTask: Task<Void, Never>?

    struct FlatTransfer: Identifiable {
        let id: String
        let transfer: SlskdTransfer
        let directory: String
    }

    private var completedTransfers: [FlatTransfer] {
        transfers.filter { $0.transfer.isCompleted }
    }

    private var inProgressTransfers: [FlatTransfer] {
        transfers.filter { $0.transfer.isInProgress }
    }

    private var failedTransfers: [FlatTransfer] {
        transfers.filter { $0.transfer.isFailed }
    }

    var body: some View {
        List {
            if isLoading && transfers.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.8)
                        Text("Loading downloads...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            if !inProgressTransfers.isEmpty {
                Section {
                    ForEach(inProgressTransfers) { item in
                        transferRow(item, state: .inProgress)
                    }
                } header: {
                    HStack {
                        Text("In Progress")
                        Spacer()
                        Text("\(inProgressTransfers.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !completedTransfers.isEmpty {
                Section {
                    ForEach(completedTransfers) { item in
                        transferRow(item, state: .completed)
                    }
                } header: {
                    HStack {
                        Text("Completed")
                        Spacer()
                        Text("\(completedTransfers.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !failedTransfers.isEmpty {
                Section {
                    ForEach(failedTransfers) { item in
                        transferRow(item, state: .failed)
                    }
                } header: {
                    HStack {
                        Text("Failed")
                        Spacer()
                        Text("\(failedTransfers.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if transfers.isEmpty && !isLoading && error == nil {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No downloads yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Search for songs and download them from the Search tab.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }

            // Bottom spacer for miniplayer
            Section { EmptyView() }
                .listRowBackground(Color.clear)
                .frame(height: 80)
        }
        .scrollIndicators(.hidden)
        .refreshable { await loadDownloads() }
        .onChange(of: isVisible) { _, visible in
            if visible {
                // Refresh immediately when switching to Downloads tab
                Task { await loadDownloads() }
                startPolling()
            } else {
                pollTask?.cancel()
            }
        }
    }

    /// Auto-poll every 3 seconds while the tab is visible
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await loadDownloads()
            }
        }
    }

    private enum TransferState { case inProgress, completed, failed }

    private func transferRow(_ item: FlatTransfer, state: TransferState) -> some View {
        HStack(spacing: 12) {
            // Format badge
            Text(item.transfer.fileExtension)
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(badgeColor(for: item.transfer.fileExtension).opacity(0.15))
                .foregroundStyle(badgeColor(for: item.transfer.fileExtension))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.transfer.displayName)
                    .font(.subheadline)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(item.transfer.displaySize)
                    Text("·")
                    Text(item.transfer.username)
                    if state == .inProgress, let pct = item.transfer.percentComplete {
                        Text("·")
                        Text("\(Int(pct))%")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if state == .inProgress, let pct = item.transfer.percentComplete {
                    ProgressView(value: pct / 100.0)
                        .tint(accentColor)
                }
            }

            Spacer()

            // State icon + delete
            if deletingIds.contains(item.id) {
                ProgressView().scaleEffect(0.7)
            } else {
                HStack(spacing: 8) {
                    switch state {
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .inProgress:
                        ProgressView().scaleEffect(0.6)
                    case .failed:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    Button {
                        deleteTransfer(item)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.8))
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func badgeColor(for ext: String) -> Color {
        switch ext {
        case "FLAC": return .blue
        case "MP3": return .orange
        case "OGG", "OPUS": return .purple
        case "M4A", "AAC": return .green
        case "WAV": return .cyan
        default: return .gray
        }
    }

    private func loadDownloads() async {
        isLoading = true
        error = nil
        do {
            let groups = try await SlskdClient.shared.getDownloads()
            var flat: [FlatTransfer] = []
            for group in groups {
                for dir in group.directories ?? [] {
                    for file in dir.files ?? [] {
                        flat.append(FlatTransfer(id: file.id, transfer: file, directory: dir.directory))
                    }
                }
            }
            // Sort: in-progress first, then completed (newest first), then failed
            flat.sort { a, b in
                let aOrder = a.transfer.isInProgress ? 0 : (a.transfer.isCompleted ? 1 : 2)
                let bOrder = b.transfer.isInProgress ? 0 : (b.transfer.isCompleted ? 1 : 2)
                if aOrder != bOrder { return aOrder < bOrder }
                return (a.transfer.endedAt ?? "") > (b.transfer.endedAt ?? "")
            }
            transfers = flat
        } catch is CancellationError {
            // ignore
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func deleteTransfer(_ item: FlatTransfer) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        deletingIds.insert(item.id)
        Task {
            try? await SlskdClient.shared.deleteTransfer(username: item.transfer.username, id: item.id)
            await MainActor.run {
                deletingIds.remove(item.id)
                transfers.removeAll { $0.id == item.id }
            }
        }
    }
}

#endif
