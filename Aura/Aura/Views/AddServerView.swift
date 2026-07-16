import SwiftUI

struct AddServerView: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var friendlyName = ""
    @State private var isTesting = false
    @State private var error: String?

    private var formValid: Bool {
        !url.isEmpty && !username.isEmpty && !password.isEmpty && !friendlyName.isEmpty
    }

    private var isInsecureURL: Bool {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http:// example.com:4533", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    TextField("Server Name (required)", text: $friendlyName)
                        .autocorrectionDisabled()
                }

                if isInsecureURL {
                    Section {
                        Label {
                            Text("This server uses an unencrypted (HTTP) connection — your password and music are sent in the clear. Use HTTPS when possible.")
                        } icon: {
                            Image(systemName: "lock.open.fill").foregroundStyle(.orange)
                        }
                        .font(.caption)
                    }
                }

                if isTesting {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Testing connection…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = error {
                    Section {
                        Label {
                            Text(error)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                        .font(.callout)
                    }
                }
            }
            .navigationTitle("add new server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await addServer() } }
                        .disabled(!formValid || isTesting)
                }
            }
        }
    }

    private func addServer() async {
        isTesting = true
        error = nil
        var serverURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverURL.hasPrefix("http://") && !serverURL.hasPrefix("https://") {
            serverURL = "https://\(serverURL)"
        }
        // Validate: only http/https with a real host (rejects file://, javascript:, garbage).
        guard let comps = URLComponents(string: serverURL),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else {
            await MainActor.run {
                error = "Enter a valid server address (e.g. https://music.example.com)"
                isTesting = false
            }
            return
        }
        let name = friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = ServerConfig(url: serverURL, username: username, password: password, friendlyName: name)

        do {
            let ok = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await SubsonicClient.shared.ping(server: server)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw ConnectionError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            if ok {
                await MainActor.run { serverManager.addServer(server); dismiss() }
            } else {
                await MainActor.run {
                    error = "Server rejected the connection — check your credentials"
                    isTesting = false
                }
            }
        } catch is ConnectionError {
            await MainActor.run {
                error = "Connection timed out — is the server address correct and reachable?"
                isTesting = false
            }
        } catch let urlError as URLError {
            await MainActor.run {
                self.error = Self.friendlyMessage(for: urlError)
                isTesting = false
            }
        } catch {
            await MainActor.run {
                self.error = "Connection failed: \(error.localizedDescription)"
                isTesting = false
            }
        }
    }

    private static func friendlyMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "No internet connection"
        case .cannotFindHost:
            return "Server not found — check the address"
        case .cannotConnectToHost:
            return "Cannot reach server — is it running?"
        case .timedOut:
            return "Connection timed out — is the server address correct and reachable?"
        case .secureConnectionFailed:
            return "SSL/TLS error — try using http:// instead of https://"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "Server certificate is not trusted — try using http://"
        default:
            return "Connection failed: \(error.localizedDescription)"
        }
    }
}

private enum ConnectionError: Error {
    case timeout
}
