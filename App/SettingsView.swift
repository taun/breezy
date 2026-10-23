import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Set when shown as a sheet. Never call `dismiss` here: as a window's root view on macOS it closes the window.
    var close: (() -> Void)?
    @State private var repo = ""
    @State private var token = ""

    var body: some View {
        Form {
            Section {
                TextField("owner/name", text: $repo)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } header: {
                Text("Repository")
            } footer: {
                Text("The GitHub repository of the Eleventy site.")
            }
            Section {
                SecureField(model.hasToken ? "Saved in the Keychain (enter to replace)" : "github_pat_…", text: $token)
            } header: {
                Text("Personal access token")
            } footer: {
                Text("Create a fine-grained token for this repository with **Contents** and **Pull requests** set to read and write. It is stored only in this device's Keychain.")
            }
            Section {
                Button("Save and connect") {
                    Task { if await model.saveSettings(repo: repo, token: token) { token = ""; close?() } }
                }
                .disabled(repo.isEmpty || (!model.hasToken && token.isEmpty) || model.isBusy)
                if model.hasToken {
                    Button("Remove token", role: .destructive) { model.signOut() }
                }
            }
            if let folder = model.localFolder {
                Section {
                    #if os(macOS)
                    Button("Show Local Files in Finder") { model.revealLocalFiles() }
                    #endif
                    Text(folder.path).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                } header: {
                    Text("Local copy")
                } footer: {
                    #if os(iOS)
                    Text("Also visible in the Files app under On My iPhone/iPad › Breezy. Edit through Breezy; changing files there directly can confuse syncing.")
                    #else
                    Text("Every branch you open is kept here so Breezy works offline. Edit through Breezy; changing files directly can confuse syncing.")
                    #endif
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            if let close {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { close() } }
            }
        }
        .onAppear { repo = model.repoString }
    }
}
