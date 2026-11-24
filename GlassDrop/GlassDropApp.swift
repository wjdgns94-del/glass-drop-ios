import SwiftUI

@main
struct GlassDropApp: App {
    @StateObject private var model = SessionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onChange(of: scenePhase) { newPhase in
                    model.scenePhaseChanged(newPhase)
                }
        }
    }
}
