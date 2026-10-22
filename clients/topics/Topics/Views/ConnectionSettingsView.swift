import SwiftUI

struct ConnectionSettingsView: View {
    @EnvironmentObject private var connection: VeetbotConnection
    @State private var token = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section("Veetbot") {
                TextField("Server URL", text: $connection.baseURLString)
                SecureField("Bearer token", text: $token, prompt: Text(connection.hasToken ? "Saved in Keychain" : "Token"))
                HStack {
                    Spacer()
                    Button("Save token") {
                        Task {
                            do {
                                try await connection.saveToken(token)
                                token = ""
                                message = "Saved."
                            } catch {
                                message = error.localizedDescription
                            }
                        }
                    }
                    .disabled(token.isEmpty)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Local development serves Veetbot over HTTPS on localhost:8443 and ignores the token.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
