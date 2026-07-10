import Foundation

#if !APPSTORE_BUILD

/// Native client for the slskd REST API (Soulseek daemon)
@Observable
final class SlskdClient {
    static let shared = SlskdClient()

    private var token: String?
    private var tokenExpiry: Date?

    // MARK: - Auth

    /// Authenticate and store JWT token
    func authenticate() async throws {
        let base = baseURL
        guard let url = URL(string: "\(base)/api/v0/session") else {
            throw SlskdError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: String] = [
            "username": AppSettings.shared.slskdUsername,
            "password": AppSettings.shared.slskdPassword
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SlskdError.authFailedDetail(base: base, statusCode: code)
        }

        let session = try JSONDecoder().decode(SlskdSession.self, from: data)
        self.token = session.token
        self.tokenExpiry = Date(timeIntervalSince1970: TimeInterval(session.expires))
    }

    private func ensureAuth() async throws {
        if token == nil || (tokenExpiry != nil && Date() > tokenExpiry!) {
            try await authenticate()
        }
    }

    private func authorizedRequest(url: URL, method: String = "GET") async throws -> URLRequest {
        try await ensureAuth()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        return request
    }

    private var baseURL: String {
        let s = AppSettings.shared
        let host = s.externalServiceURL
        let origin = host.contains("://") ? host : "http://\(host)"
        return "\(origin):\(s.externalServicePort)"
    }

    // MARK: - Search

    /// Start a search and return the search ID
    func search(query: String) async throws -> SlskdSearch {
        guard let url = URL(string: "\(baseURL)/api/v0/searches") else {
            throw SlskdError.invalidURL
        }

        var request = try await authorizedRequest(url: url, method: "POST")
        let body = ["searchText": query]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 201 else {
            throw SlskdError.requestFailed
        }

        return try JSONDecoder().decode(SlskdSearch.self, from: data)
    }

    /// Get search status
    func getSearch(id: String) async throws -> SlskdSearch {
        guard let url = URL(string: "\(baseURL)/api/v0/searches/\(id)") else {
            throw SlskdError.invalidURL
        }

        let request = try await authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(SlskdSearch.self, from: data)
    }

    /// Get search responses (the actual file results)
    func getSearchResponses(id: String) async throws -> [SlskdSearchResponse] {
        guard let url = URL(string: "\(baseURL)/api/v0/searches/\(id)/responses") else {
            throw SlskdError.invalidURL
        }

        let request = try await authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([SlskdSearchResponse].self, from: data)
    }

    /// Delete a search
    func deleteSearch(id: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/v0/searches/\(id)") else { return }
        let request = try await authorizedRequest(url: url, method: "DELETE")
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Downloads

    /// Queue a file for download
    func download(username: String, files: [SlskdDownloadRequest]) async throws -> SlskdDownloadResponse {
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        guard let url = URL(string: "\(baseURL)/api/v0/transfers/downloads/\(encoded)") else {
            throw SlskdError.invalidURL
        }

        var request = try await authorizedRequest(url: url, method: "POST")
        request.httpBody = try JSONEncoder().encode(files)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SlskdError.requestFailed
        }

        return try JSONDecoder().decode(SlskdDownloadResponse.self, from: data)
    }

    /// Get all current downloads
    func getDownloads() async throws -> [SlskdTransferGroup] {
        guard let url = URL(string: "\(baseURL)/api/v0/transfers/downloads") else {
            throw SlskdError.invalidURL
        }

        let request = try await authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([SlskdTransferGroup].self, from: data)
    }

    /// Delete a specific transfer
    func deleteTransfer(username: String, id: String) async throws {
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        guard let url = URL(string: "\(baseURL)/api/v0/transfers/downloads/\(encoded)/\(id)") else { return }
        let request = try await authorizedRequest(url: url, method: "DELETE")
        _ = try? await URLSession.shared.data(for: request)
    }
}

// MARK: - Error

enum SlskdError: LocalizedError {
    case invalidURL
    case authFailed
    case authFailedDetail(base: String, statusCode: Int)
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid slskd URL"
        case .authFailed: return "Authentication failed — check credentials"
        case .authFailedDetail(let base, let code):
            return "Auth failed (HTTP \(code)) at \(base) — check host, port & credentials in Settings"
        case .requestFailed: return "Request failed"
        }
    }
}

// MARK: - API Models

struct SlskdSession: Codable {
    let token: String
    let expires: Int
}

struct SlskdSearch: Codable {
    let id: String
    let searchText: String
    let state: String
    let fileCount: Int
    let responseCount: Int
    let isComplete: Bool

    var isFinished: Bool {
        isComplete || state.contains("Completed")
    }
}

struct SlskdSearchResponse: Codable {
    let username: String
    let fileCount: Int
    let lockedFileCount: Int
    let uploadSpeed: Int?
    let hasFreeUploadSlot: Bool?
    let queueLength: Int?
    let files: [SlskdFile]
    let lockedFiles: [SlskdFile]?
}

struct SlskdFile: Codable, Identifiable {
    let filename: String
    let size: Int64
    let bitRate: Int?
    let length: Int?
    let code: Int?
    let isLocked: Bool?

    var id: String { filename }

    /// Extract just the file name from the full path
    var displayName: String {
        let parts = filename.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        return String(parts.last ?? Substring(filename))
    }

    /// File extension
    var fileExtension: String {
        let parts = displayName.split(separator: ".")
        return parts.count > 1 ? String(parts.last!).uppercased() : "?"
    }

    /// Human-readable size
    var displaySize: String {
        let mb = Double(size) / 1_048_576.0
        if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        } else {
            return "\(size / 1024) KB"
        }
    }

    /// Is this an audio file?
    var isAudio: Bool {
        let ext = fileExtension.lowercased()
        return ["mp3", "flac", "ogg", "opus", "m4a", "aac", "wav", "wma", "alac", "ape", "wv"].contains(ext)
    }

    /// Duration string
    var displayDuration: String? {
        guard let length = length, length > 0 else { return nil }
        let min = length / 60
        let sec = length % 60
        return String(format: "%d:%02d", min, sec)
    }
}

struct SlskdDownloadRequest: Codable {
    let filename: String
    let size: Int64
}

struct SlskdDownloadResponse: Codable {
    let enqueued: [SlskdTransfer]?
    let failed: [SlskdTransfer]?
}

struct SlskdTransfer: Codable, Identifiable {
    let id: String
    let username: String
    let filename: String
    let size: Int64
    let state: String
    let bytesTransferred: Int64?
    let percentComplete: Double?
    let averageSpeed: Double?
    let endedAt: String?
    let startedAt: String?

    var displayName: String {
        let parts = filename.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        return String(parts.last ?? Substring(filename))
    }

    var isCompleted: Bool {
        state.contains("Completed") && state.contains("Succeeded")
    }

    var isInProgress: Bool {
        state.contains("InProgress") || state.contains("Requested") || state.contains("Queued")
    }

    var isFailed: Bool {
        (state.contains("Completed") && !state.contains("Succeeded")) ||
        state.contains("Errored") || state.contains("Cancelled") || state.contains("TimedOut")
    }

    var fileExtension: String {
        let parts = displayName.split(separator: ".")
        return parts.count > 1 ? String(parts.last!).uppercased() : "?"
    }

    var displaySize: String {
        let mb = Double(size) / 1_048_576.0
        if mb >= 1.0 { return String(format: "%.1f MB", mb) }
        return "\(size / 1024) KB"
    }
}

struct SlskdTransferGroup: Codable {
    let username: String
    let directories: [SlskdTransferDirectory]?
}

struct SlskdTransferDirectory: Codable {
    let directory: String
    let fileCount: Int
    let files: [SlskdTransfer]?
}

#endif
