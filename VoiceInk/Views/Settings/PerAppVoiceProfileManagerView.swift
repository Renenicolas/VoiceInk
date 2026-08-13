import SwiftUI
import AppKit

/// Settings sheet: opt-in "teach my voice from existing writing" bootstrap for a chosen app's
/// profile, plus a list to view/edit/clear any app's stored profile.
///
/// LOCAL ONLY: distillation runs through the same tools-off local `claude` CLI as automatic
/// background consolidation (`PerAppVoiceProfileService` — always `claude -p`, no
/// `--allowedTools`, regardless of the user's own Local CLI settings), and results land in the
/// same encrypted-at-rest store as automatic per-app memory (`PerAppStyleMemory`). Nothing
/// pasted or distilled here ever touches the network.
struct PerAppVoiceProfileManagerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var installedApps: [InstalledAppInfo] = []
    @State private var isLoadingApps = false

    @State private var teachBundleID: String?
    @State private var teachSampleText = ""
    @State private var isTeaching = false
    @State private var teachError: String?

    @State private var trackedApps: [String] = []
    @State private var expandedBundleID: String?
    @State private var editedProfile = ""

    var body: some View {
        NavigationStack {
            Form {
                teachSection
                manageSection
            }
            .formStyle(.grouped)
            .navigationTitle("Per-App Voice Profiles")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 560)
        .onAppear {
            loadInstalledAppsIfNeeded()
            refreshTrackedApps()
            if teachBundleID == nil {
                teachBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }
        }
    }

    // MARK: - Teach

    private var teachSection: some View {
        Section {
            Picker("App", selection: $teachBundleID) {
                Text("Choose an app").tag(String?.none)
                ForEach(installedApps, id: \.bundleId) { app in
                    Text(app.name).tag(String?.some(app.bundleId))
                }
            }
            .disabled(installedApps.isEmpty)

            TextEditor(text: $teachSampleText)
                .frame(minHeight: 140)
                .overlay(alignment: .topLeading) {
                    if teachSampleText.isEmpty {
                        Text("Paste a few emails, messages, or docs written in your own voice…")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            Text("Stays encrypted on this device. Distilled locally via the tools-off `claude` CLI — no network access, nothing sent anywhere.")
                .settingsDescription()

            if let teachError {
                Text(teachError)
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
            }

            HStack {
                Spacer()
                if isTeaching {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Teach") {
                    teach()
                }
                .disabled(isTeaching || teachBundleID == nil || teachSampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Teach My Voice From Existing Writing")
        } footer: {
            Text("Paste sample text you've written in a specific app. Nino Voice distills it into that app's starting voice profile.")
        }
    }

    private func teach() {
        guard let bundleID = teachBundleID else { return }
        let sample = teachSampleText
        isTeaching = true
        teachError = nil
        Task {
            do {
                let profile = try await PerAppVoiceProfileService.distill(material: sample)
                guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TeachError.emptyResult
                }
                PerAppStyleMemory.shared.setProfile(profile, forApp: bundleID)
                await MainActor.run {
                    isTeaching = false
                    teachSampleText = ""
                    refreshTrackedApps()
                }
            } catch {
                await MainActor.run {
                    isTeaching = false
                    teachError = "Couldn't distill a profile: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Manage

    private var manageSection: some View {
        Section("Learned Per-App Profiles") {
            if trackedApps.isEmpty {
                Text("No app has a learned style yet.")
                    .settingsDescription()
            }
            ForEach(trackedApps, id: \.self) { bundleID in
                appRow(bundleID)
            }
        }
    }

    @ViewBuilder
    private func appRow(_ bundleID: String) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedBundleID == bundleID },
            set: { isExpanded in
                if isExpanded {
                    expandedBundleID = bundleID
                    editedProfile = PerAppStyleMemory.shared.rawProfile(forApp: bundleID) ?? ""
                } else if expandedBundleID == bundleID {
                    expandedBundleID = nil
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 8) {
                if PerAppStyleMemory.shared.rawProfile(forApp: bundleID) == nil {
                    Text("No profile distilled yet — still learning from recent dictations in this app.")
                        .settingsDescription()
                }

                TextEditor(text: $editedProfile)
                    .frame(minHeight: 100)

                HStack {
                    Button("Clear", role: .destructive) {
                        PerAppStyleMemory.shared.clear(forApp: bundleID)
                        expandedBundleID = nil
                        refreshTrackedApps()
                    }
                    Spacer()
                    Button("Save") {
                        PerAppStyleMemory.shared.setProfile(editedProfile, forApp: bundleID)
                        expandedBundleID = nil
                    }
                    .disabled(editedProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                if let icon = TriggerAppIconCache.shared.icon(for: bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(appDisplayName(bundleID))
                    Text(bundleID)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func refreshTrackedApps() {
        trackedApps = Array(PerAppStyleMemory.shared.trackedApps().reversed())
    }

    private func loadInstalledAppsIfNeeded() {
        guard installedApps.isEmpty, !isLoadingApps else { return }
        isLoadingApps = true
        DispatchQueue.global(qos: .utility).async {
            let apps = InstalledApps.load()
            Task { @MainActor in
                self.installedApps = apps
                self.isLoadingApps = false
            }
        }
    }

    private func appDisplayName(_ bundleID: String) -> String {
        if let match = installedApps.first(where: { $0.bundleId == bundleID }) {
            return match.name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    private enum TeachError: LocalizedError {
        case emptyResult
        var errorDescription: String? {
            "The local `claude` CLI returned an empty profile."
        }
    }
}
