import SwiftUI
import OSLog

enum ViewType: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case modes = "Modes"
    case models = "AI Models"
    case transcribeAudio = "Transcribe Audio"
    case history = "History"
    case audio = "Audio"
    case dictionary = "Dictionary"
    case brain = "Brain"
    case sweep = "Sweep"
    case agent = "Agent"
    case settings = "Settings"
    case license = "Nino Voice Pro"

    var id: String { rawValue }
}

struct ContentView: View {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ContentView")
    private static let detailBackgroundTintOpacity = 0.50
    @State private var selectedView: ViewType = .dashboard
    @StateObject private var entitlements = NinoEntitlementsModel()

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(
                selectedView: $selectedView,
                visibility: entitlements.state.visibility
            )

            detailContent
        }
        .frame(width: AppWindowLayout.width)
        .frame(minHeight: AppWindowLayout.minimumHeight)
        .onAppear {
            logger.notice("ContentView appeared")
        }
        .onDisappear {
            logger.notice("ContentView disappeared")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDestination)) { notification in
            if let destination = notification.userInfo?["destination"] as? String,
               let viewType = ViewType.allCases.first(where: { $0.rawValue == destination }) {
                logger.notice("navigateToDestination received: \(destination, privacy: .public)")
                selectedView = viewType
            }
        }
        .task {
            while !Task.isCancelled {
                await entitlements.refresh()
                if !selectedView.isVisible(with: entitlements.state.visibility) {
                    selectedView = entitlements.state.visibility.sectorIDs.contains("voice") ? .dashboard : .settings
                }
                try? await Task.sleep(for: .seconds(ninoEntitlementsRefreshInterval))
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        detailView(for: selectedView)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(detailBackground)
    }

    private var detailBackground: some View {
        ZStack {
            VisualEffectView(
                material: .sidebar,
                blendingMode: .behindWindow
            )

            AppTheme.Surface.window
                .opacity(Self.detailBackgroundTintOpacity)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
    
    @ViewBuilder
    private func detailView(for viewType: ViewType) -> some View {
        switch viewType {
        case .dashboard:
            DashboardView()
        case .models:
            ModelManagementView()
        case .transcribeAudio:
            AudioTranscribeView()
        case .history:
            InlineHistoryView()
        case .audio:
            AudioSetupView()
        case .dictionary:
            DictionarySettingsView()
        case .modes:
            ModeView()
        case .brain:
            NinoSectorPlaceholderView(sector: .brain)
        case .sweep:
            NinoSectorPlaceholderView(sector: .sweep)
        case .agent:
            NinoSectorPlaceholderView(sector: .agent)
        case .settings:
            SettingsView()
        case .license:
            LicenseManagementView()
        }
    }
}

private extension ViewType {
    func isVisible(with visibility: NinoSidebarVisibility) -> Bool {
        switch self {
        case .dashboard, .modes, .models, .transcribeAudio, .history, .audio, .dictionary:
            return visibility.sectorIDs.contains("voice")
        case .brain:
            return visibility.sectorIDs.contains("brain")
        case .sweep:
            return visibility.sectorIDs.contains("sweep")
        case .agent:
            return visibility.sectorIDs.contains("agent")
        case .settings, .license:
            return true
        }
    }
}

private struct NinoSectorPlaceholderView: View {
    let sector: NinoSector

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            Text(sector.label)
                .font(.title2.weight(.semibold))
            Text("This sector is included with your licence. Its screen is not built yet.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
