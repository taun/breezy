import BreezyKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Set when shown as a sheet. Never call `dismiss` here: as a window's root view on macOS it closes the window.
    var close: (() -> Void)?
    @State private var repo = ""
    @State private var token = ""
    @State private var website = ""
    @State private var filingIssue = false

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
                switch model.tokenSync {
                case .synced:
                    Label("In iCloud Keychain: your other devices get it too.", systemImage: "checkmark.icloud").foregroundStyle(.secondary)
                case let .deviceOnly(reason):
                    Label("Saved on this device only, not syncing: \(reason)", systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
                case .missing:
                    Button("Check iCloud Keychain Again") { Task { await model.refreshToken() } }
                }
            } header: {
                Text("Personal access token")
            } footer: {
                Text("Create a fine-grained token for this repository with **Contents** and **Pull requests** set to read and write, and optionally **Actions** read to show when the website has rebuilt. To file issues on Breezy from the app, also add the taun/breezy repository with **Issues** read and write. It is kept in iCloud Keychain, so your other devices signed in to the same Apple ID get it automatically.")
            }
            Section {
                TextField("https://www.example.org/", text: $website)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit { model.setWebsiteURL(website) }
            } header: {
                Text("Website")
            } footer: {
                Text("Opened by View Website. Filled in from the site's CNAME file.")
            }
            Section {
                Button("Save and connect") {
                    Task { if await model.saveSettings(repo: repo, token: token) { token = ""; close?() } }
                }
                .disabled(repo.isEmpty || (!model.hasToken && token.isEmpty) || model.isBusy)
                if model.hasToken {
                    Button("Remove Token from All Devices", role: .destructive) { model.signOut() }
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
            Section {
                Button("File an Issue…") { filingIssue = true }
            } footer: {
                Text("Report a bug or suggest an enhancement for Breezy without leaving the app.")
            }
            Section {
                Text(AppVersion.current)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $filingIssue) {
            NavigationStack { IssueView(close: { filingIssue = false }) }.macSheetFrame(minWidth: 460, minHeight: 420)
        }
        .navigationTitle("Settings")
        .toolbar {
            if let close {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { close() } }
            }
        }
        .onAppear {
            repo = model.repoString
            website = model.websiteURL?.absoluteString ?? ""
        }
        .onDisappear { if website != (model.websiteURL?.absoluteString ?? "") { model.setWebsiteURL(website) } }
    }
}
