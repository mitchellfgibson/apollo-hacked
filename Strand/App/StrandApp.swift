import SwiftUI

@main
struct StrandApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.live)
                .environmentObject(model.repo)
                .environmentObject(model.profile)
                .environmentObject(model.behavior)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .rootWindowChrome()
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)

        // Menu-bar extra: glanceable live HR + a compact popover. macOS only.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(model.repo)
                .environmentObject(model.live)
        } label: {
            MenuBarLabel()
                .environmentObject(model.repo)
                .environmentObject(model.live)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

private extension View {
    /// The Mac window wants a minimum content size; on iPhone the app is full-screen, so a
    /// `.frame(minWidth:…)` would wrongly clamp the layout. Apply desktop chrome on macOS only.
    @ViewBuilder func rootWindowChrome() -> some View {
        #if os(macOS)
        self.frame(minWidth: 1000, minHeight: 700)
        #else
        self
        #endif
    }
}
