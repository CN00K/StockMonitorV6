import SwiftUI

@main
struct MonitorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = MonitorViewModel()

    var body: some Scene {
        WindowGroup {
            MonitorView(model: model)
                .task { model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.start()
                    } else if phase == .background {
                        model.stop()
                    }
                }
        }
    }
}
