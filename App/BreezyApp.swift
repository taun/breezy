import SwiftUI

@main
struct BreezyApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Back in front: pick up a token iCloud Keychain delivered meanwhile, and sync.
                    if phase == .active { Task { await model.refreshToken(); await model.sync() } }
                    // Leaving: write the cursor moves still held back (they are batched while typing).
                    else { try? model.workspace?.flushEditorStates() }
                }
        }
        .commands {
            // View ▸ Show/Hide Sidebar (⌃⌘S) on the Mac and with an iPad keyboard.
            SidebarCommands()
        }
    }
}
