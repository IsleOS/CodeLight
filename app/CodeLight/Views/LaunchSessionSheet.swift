import SwiftUI
import CodeLightProtocol

/// Sheet to remote-launch a new Claude session on a paired Mac.
/// Step 1: pick a launch preset (synced from the Mac).
/// Step 2: pick a project path (recent + custom).
/// Step 3: tap Launch → POST /v1/sessions/launch.
struct LaunchSessionSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let mac: LinkedMac

    @State private var presets: [LaunchPresetDTO] = []
    @State private var projects: [KnownProjectDTO] = []
    @State private var isLoading = true
    @State private var selectedPreset: LaunchPresetDTO?
    @State private var selectedProjectPath: String?
    @State private var customPath: String = ""
    @State private var isLaunching = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var pathToUse: String {
        if !customPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return customPath.trimmingCharacters(in: .whitespaces)
        }
        return selectedProjectPath ?? ""
    }

    private var canLaunch: Bool {
        selectedPreset != nil && !pathToUse.isEmpty && !isLaunching
    }

    var body: some View {
        Form {
            // Preset section
            Section {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if presets.isEmpty {
                    Text(String(localized: "no_presets_on_mac"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(presets) { preset in
                        Button {
                            Haptics.selection()
                            selectedPreset = preset
                        } label: {
                            HStack {
                                Image(systemName: preset.icon ?? "terminal")
                                    .foregroundStyle(Theme.brand)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .foregroundStyle(.primary)
                                    Text(preset.command)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if selectedPreset?.id == preset.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.brand)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text(String(localized: "launch_preset"))
            }

            // Project paths section
            Section {
                if !projects.isEmpty {
                    ForEach(projects) { project in
                        Button {
                            Haptics.selection()
                            selectedProjectPath = project.path
                            customPath = ""
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                        .foregroundStyle(.primary)
                                    Text(shortenPath(project.path))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if selectedProjectPath == project.path && customPath.isEmpty {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.brand)
                                }
                            }
                        }
                    }
                } else if !isLoading {
                    Text(String(localized: "no_recent_projects"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "recent_projects"))
            }

            // Custom path
            Section {
                TextField("/Users/you/code/myproject", text: $customPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .onChange(of: customPath) { _, new in
                        if !new.isEmpty { selectedProjectPath = nil }
                    }
            } header: {
                Text(String(localized: "custom_path"))
            }

            // Status
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            if let successMessage {
                Section {
                    Text(successMessage)
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
        }
        .navigationTitle(String(localized: "launch_on_mac"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(String(localized: "cancel")) { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await launch() }
                } label: {
                    if isLaunching {
                        ProgressView()
                    } else {
                        Text(String(localized: "launch"))
                            .fontWeight(.semibold)
                    }
                }
                .disabled(!canLaunch)
            }
        }
        .task {
            await loadPresetsAndProjects()
        }
    }

    // MARK: - Actions

    private func loadPresetsAndProjects() async {
        guard let socket = appState.socket else {
            isLoading = false
            errorMessage = String(localized: "not_connected")
            return
        }
        isLoading = true
        async let presetsTask = (try? await socket.fetchPresets(macDeviceId: mac.deviceId)) ?? []
        async let projectsTask = (try? await socket.fetchProjects(macDeviceId: mac.deviceId)) ?? []
        let (p, pr) = await (presetsTask, projectsTask)
        presets = p
        projects = pr
        if selectedPreset == nil { selectedPreset = p.first }
        if selectedProjectPath == nil { selectedProjectPath = pr.first?.path }
        isLoading = false
    }

    private func launch() async {
        guard let socket = appState.socket, let preset = selectedPreset else { return }
        Haptics.rigid()
        isLaunching = true
        errorMessage = nil
        successMessage = nil
        do {
            try await socket.launchSession(macDeviceId: mac.deviceId, presetId: preset.id, projectPath: pathToUse)
            Haptics.success()
            // Dismiss immediately — the parent SessionList shows the new
            // session as soon as the Mac broadcasts `sessions-changed`.
            // The artificial 800ms delay made every launch feel sluggish.
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
        isLaunching = false
    }

    private func shortenPath(_ path: String) -> String {
        var p = path
        if let home = ProcessInfo.processInfo.environment["HOME"], p.hasPrefix(home) {
            p = "~" + p.dropFirst(home.count)
        }
        return p
    }
}
