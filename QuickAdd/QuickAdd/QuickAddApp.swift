import SwiftData
import SwiftUI

@main
struct QuickAddApp: App {

    @State private var settings = AppSettings()
    @State private var calendarStore = CalendarStore()

    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: CaptureSession.self, DraftItem.self)
        } catch {
            // The local store is what guarantees a capture is never lost.
            // Running without it would break that promise silently, so fail
            // loudly instead.
            fatalError("无法初始化本地存储：\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(calendarStore)
        }
        .modelContainer(container)
    }
}
