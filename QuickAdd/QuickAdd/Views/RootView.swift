import SwiftData
import SwiftUI

struct RootView: View {

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(CalendarStore.self) private var calendarStore

    @State private var coordinator: CaptureCoordinator?
    @State private var showingSettings = false
    @State private var showingLog = false

    var body: some View {
        NavigationStack {
            Group {
                if let coordinator {
                    CaptureView(coordinator: coordinator)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("闪记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A leading button and a sheet rather than an edge-swipe drawer:
                // the drawer gesture collides with the system back swipe and is
                // not a pattern Apple's own apps use (PRD §10).
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingLog = true } label: {
                        Label("日志", systemImage: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingLog) { LogView() }
        }
        .task {
            guard coordinator == nil else { return }
            coordinator = CaptureCoordinator(
                context: context, settings: settings, calendarStore: calendarStore)
        }
    }
}
