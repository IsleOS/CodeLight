import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity widget for Dynamic Island and Lock Screen.
struct CodeLightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CodeLightActivityAttributes.self) { context in
            // Lock Screen / StandBy presentation
            LockScreenView(state: context.state, attributes: context.attributes)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded Dynamic Island
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        PixelCharacterView(state: animationState(for: context.state.phase))
                            .scaleEffect(0.6)
                            .frame(width: 32, height: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.state.projectName)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(.white)
                            Text(phaseLabel(context.state.phase))
                                .font(.system(size: 10))
                                .foregroundStyle(phaseColor(context.state.phase))
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 50)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        // Tool info (if active)
                        if let toolName = context.state.toolName, !toolName.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: toolIcon(toolName))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.cyan)
                                Text(toolName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .foregroundStyle(.white.opacity(0.8))
                                Spacer()
                            }
                        }

                        // Last user question
                        if let userMsg = context.state.lastUserMessage, !userMsg.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.blue)
                                    .padding(.top, 1)
                                Text(userMsg)
                                    .font(.system(size: 11))
                                    .lineLimit(2)
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }

                        // Claude's latest response summary
                        if let assistant = context.state.lastAssistantSummary, !assistant.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.green)
                                    .padding(.top, 1)
                                Text(assistant)
                                    .font(.system(size: 11))
                                    .lineLimit(2)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                // Compact leading — pixel cat + project name
                HStack(spacing: 4) {
                    PixelCharacterView(state: animationState(for: context.state.phase))
                        .scaleEffect(0.4)
                        .frame(width: 22, height: 20)
                    Text(context.state.projectName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .frame(maxWidth: 70)
                }
            } compactTrailing: {
                // Compact trailing — phase label or tool name
                Text(compactText(context.state))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(phaseColor(context.state.phase))
                    .lineLimit(1)
                    .frame(maxWidth: 70)
            } minimal: {
                // Minimal — just the cat face (very small)
                PixelCharacterView(state: animationState(for: context.state.phase))
                    .scaleEffect(0.4)
                    .frame(width: 20, height: 18)
            }
            .keylineTint(phaseColor(context.state.phase))
        }
    }
}

// MARK: - Lock Screen View

private struct LockScreenView: View {
    let state: CodeLightActivityAttributes.ContentState
    let attributes: CodeLightActivityAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top row: cat + project + status + timer
            HStack(spacing: 12) {
                PixelCharacterView(state: animationState(for: state.phase))
                    .frame(width: 52, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(state.projectName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(phaseColor(state.phase))
                            .frame(width: 6, height: 6)
                        Text(phaseLabel(state.phase))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))

                        if let toolName = state.toolName, !toolName.isEmpty {
                            Text("·")
                                .foregroundStyle(.white.opacity(0.3))
                            Image(systemName: toolIcon(toolName))
                                .font(.system(size: 9))
                            Text(toolName)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                Text(state.startedAt, style: .timer)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Messages section
            if state.lastUserMessage != nil || state.lastAssistantSummary != nil {
                Divider()
                    .background(.white.opacity(0.1))

                VStack(alignment: .leading, spacing: 6) {
                    if let userMsg = state.lastUserMessage, !userMsg.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.blue)
                                .padding(.top, 2)
                            Text(userMsg)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(2)
                        }
                    }

                    if let assistant = state.lastAssistantSummary, !assistant.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                                .padding(.top, 2)
                            Text(assistant)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(3)
                        }
                    }
                }
            }
        }
        .padding(14)
    }
}

// MARK: - Compact Text

private func compactText(_ state: CodeLightActivityAttributes.ContentState) -> String {
    if let toolName = state.toolName, !toolName.isEmpty {
        return toolName
    }
    return phaseLabel(state.phase)
}

// MARK: - Phase → AnimationState mapping

private func animationState(for phase: String) -> AnimationState {
    switch phase {
    case "thinking": return .thinking
    case "tool_running": return .working
    case "waiting_approval": return .needsYou
    case "idle": return .idle
    case "ended": return .done
    case "error": return .error
    default: return .idle
    }
}

// MARK: - Phase Helpers

private func phaseColor(_ phase: String) -> Color {
    switch phase {
    case "thinking": return .purple
    case "tool_running": return .cyan
    case "waiting_approval": return .orange
    case "idle": return .gray
    case "ended": return .green
    case "error": return .red
    default: return .gray
    }
}

private func phaseLabel(_ phase: String) -> String {
    switch phase {
    case "thinking": return "Thinking..."
    case "tool_running": return "Running"
    case "waiting_approval": return "Needs you"
    case "idle": return "Idle"
    case "ended": return "Done"
    case "error": return "Error"
    default: return phase
    }
}

private func toolIcon(_ name: String) -> String {
    switch name.lowercased() {
    case "bash": return "terminal"
    case "read": return "doc.text"
    case "write": return "doc.badge.plus"
    case "edit": return "pencil"
    case "glob": return "folder.badge.magnifyingglass"
    case "grep": return "magnifyingglass"
    case "task": return "checklist"
    default: return "wrench.and.screwdriver.fill"
    }
}
