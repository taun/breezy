import SwiftUI

@main
struct BreezyApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if os(macOS)
        // Separate windows, never merged into tabs: each window is there to show its own node beside the others.
        // (This also takes Merge All Windows and the tab bar out of the Window menu.)
        NSWindow.allowsAutomaticWindowTabbing = false
        #endif
    }

    var body: some Scene {
        // Windows share the model; each has its own selection and sheets (Windows.swift). Opened with a node by
        // Open in New Window; File › New Window opens one with none. Several windows on the Mac only (Info-iOS.plist).
        WindowGroup(for: OpenedNode.self) { $opened in
            WindowRoot(opened: opened)
                .environment(model)
                .task { await model.start() }
        }
        // The app's phase, not a window's: once for all windows.
        .onChange(of: scenePhase) { _, phase in
            // Back in front: pick up a token iCloud Keychain delivered meanwhile, and sync.
            if phase == .active { Task { await model.refreshToken(); await model.sync() } }
            // Leaving: write the cursor moves still held back (they are batched while typing).
            else { try? model.workspace?.flushEditorStates() }
        }
        .commands {
            // View ▸ Show/Hide Sidebar (⌃⌘S) on the Mac and with an iPad keyboard.
            SidebarCommands()
        }
    }
}
