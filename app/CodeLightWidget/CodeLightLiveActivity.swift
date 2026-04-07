import ActivityKit
import SwiftUI
import WidgetKit

/// Global CodeLight Live Activity — shows aggregate session state.
struct CodeLightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CodeLightActivityAttributes.self) { context in
            LockScreenView(state: context.state, attributes: context.attributes)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view — cat + project + phase + session counts + timer
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        PixelCharacterView(state: animationState(for: context.state.phase))
                            .scaleEffect(0.5)
                            .frame(width: 28, height: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.state.projectName)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(.white)
                            if context.state.activeSessions > 1 {
                                Text("\(context.state.activeSessions) active")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 4) {
                        if let toolName = context.state.toolName, !toolName.isEmpty {
                            Image(systemName: toolIcon(toolName))
                                .font(.system(size: 10))
                            Text(toolName)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                        } else {
                            Text(phaseLabel(context.state.phase))
                                .font(.system(size: 11))
                        }
                    }
                    .foregroundStyle(phaseColor(context.state.phase))
                }

                DynamicIslandExpandedRegion(.bottom) {
                    // Single line: most recent message (assistant summary preferred)
                    if let assistant = context.state.lastAssistantSummary, !assistant.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                                .foregroundStyle(.green)
                            Text(assistant)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .foregroundStyle(.white.opacity(0.75))
                            Spacer()
                        }
                        .padding(.horizontal, 2)
                    } else if let userMsg = context.state.lastUserMessage, !userMsg.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.blue)
                            Text(userMsg)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .foregroundStyle(.white.opacity(0.9))
                            Spacer()
                        }
                        .padding(.horizontal, 2)
                    }
                }
            } compactLeading: {
                // Cat + rotating status text. Cat is scaled down aggressively to
                // free up horizontal budget for the rotating text, which is the
                // more information-dense piece.
                HStack(spacing: 3) {
                    PixelCharacterView(state: animationState(for: context.state.phase))
                        .scaleEffect(0.36)
                        .frame(width: 18, height: 18)
                    RotatingCompactText(state: context.state)
                }
            } compactTrailing: {
                // Project name on the trailing side with middle truncation so long
                // folder names still show both ends.
                Text(context.state.projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white)
            } minimal: {
                PixelCharacterView(state: animationState(for: context.state.phase))
                    .scaleEffect(0.4)
                    .frame(width: 20, height: 18)
            }
            .keylineTint(phaseColor(context.state.phase))
        }
    }
}

// MARK: - Rotating Compact Text

struct RotatingCompactText: View {
    let state: CodeLightActivityAttributes.ContentState

    private var messages: [String] {
        var items: [String] = []
        if let tool = state.toolName, !tool.isEmpty {
            items.append(tool)
        } else {
            items.append(phaseLabel(state.phase))
        }
        if let q = state.lastUserMessage, !q.isEmpty {
            items.append(q)
        }
        if let a = state.lastAssistantSummary, !a.isEmpty {
            items.append(a)
        }
        return items
    }

    var body: some View {
        let now = Date()
        let dates: [Date] = (0..<120).map { now.addingTimeInterval(Double($0) * 2.0) }

        TimelineView(.explicit(dates)) { context in
            let secs = Int(context.date.timeIntervalSinceReferenceDate / 2.0)
            let index = abs(secs) % max(messages.count, 1)
            Text(messages[index])
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(phaseColor(state.phase))
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.85)
        }
    }
}

// MARK: - Lock Screen View

private struct LockScreenView: View {
    let state: CodeLightActivityAttributes.ContentState
    let attributes: CodeLightActivityAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top row: cat + project + phase + timer
            HStack(spacing: 12) {
                PixelCharacterView(state: animationState(for: state.phase))
                    .frame(width: 52, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(state.projectName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if state.activeSessions > 1 {
                            Text("(\(state.activeSessions))")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }

                    HStack(spacing: 4) {
                        Circle().fill(phaseColor(state.phase)).frame(width: 6, height: 6)
                        Text(phaseLabel(state.phase))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))

                        if let toolName = state.toolName, !toolName.isEmpty {
                            Text("·").foregroundStyle(.white.opacity(0.3))
                            Image(systemName: toolIcon(toolName)).font(.system(size: 9))
                            Text(toolName).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                Text(state.startedAtDate, style: .timer)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }

            if state.lastUserMessage != nil || state.lastAssistantSummary != nil {
                Divider().background(.white.opacity(0.1))
                VStack(alignment: .leading, spacing: 6) {
                    if let userMsg = state.lastUserMessage, !userMsg.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "person.fill").font(.system(size: 10)).foregroundStyle(.blue).padding(.top, 2)
                            Text(userMsg).font(.system(size: 12)).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                        }
                    }
                    if let assistant = state.lastAssistantSummary, !assistant.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(.green).padding(.top, 2)
                            Text(assistant).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(3)
                        }
                    }
                }
            }
        }
        .padding(14)
    }
}

// MARK: - Helpers

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
    case "thinking": return "Thinking"
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
