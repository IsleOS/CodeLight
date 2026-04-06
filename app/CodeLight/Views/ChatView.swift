import SwiftUI

/// Chat view with markdown rendering and lazy message loading.
struct ChatView: View {
    @EnvironmentObject var appState: AppState
    let sessionId: String

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMoreOlder = false
    @State private var selectedModel = "opus"
    @State private var selectedMode = "auto"

    private let models = ["opus", "sonnet", "haiku"]
    private let modes = ["auto", "default", "plan"]

    var body: some View {
        VStack(spacing: 0) {
            // Messages with lazy loading
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        // Load more button at top
                        if hasMoreOlder {
                            Button {
                                Task { await loadOlderMessages() }
                            } label: {
                                if isLoadingMore {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .padding(8)
                                } else {
                                    Text(String(localized: "load_earlier_messages"))
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                        .frame(maxWidth: .infinity)
                                        .padding(8)
                                }
                            }
                            .id("loadMore")
                        }

                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding()
                        }

                        ForEach(messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input bar
            composeBar
        }
        .navigationTitle(sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMessages() }
        .refreshable { await loadMessages() }
        .onReceive(appState.newMessageSubject) { event in
            guard event.sessionId == sessionId else { return }
            if !messages.contains(where: { $0.id == event.message.id }) {
                messages.append(event.message)
            }
        }
    }

    // MARK: - Compose Bar

    private var composeBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(models, id: \.self) { model in
                        Button(model.capitalized) {
                            selectedModel = model
                            appState.updateModelMode(sessionId: sessionId, model: model, mode: selectedMode)
                        }
                    }
                } label: {
                    Label(selectedModel.capitalized, systemImage: "cpu")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Menu {
                    ForEach(modes, id: \.self) { mode in
                        Button(mode.capitalized) {
                            selectedMode = mode
                            appState.updateModelMode(sessionId: sessionId, model: selectedModel, mode: mode)
                        }
                    }
                } label: {
                    Label(selectedMode.capitalized, systemImage: "shield")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Spacer()
            }

            HStack(spacing: 8) {
                TextField(String(localized: "message_placeholder"), text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .lineLimit(1...5)

                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(inputText.isEmpty ? .gray : .blue)
                }
                .disabled(inputText.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Data

    private var sessionTitle: String {
        appState.sessions.first { $0.id == sessionId }?.metadata?.title ?? String(localized: "session")
    }

    private func loadMessages() async {
        isLoading = true
        if let socket = appState.socket {
            let result = (try? await socket.fetchMessages(sessionId: sessionId, limit: 50)) ?? SocketClient.FetchResult(messages: [], hasMore: false)
            messages = result.messages
            hasMoreOlder = result.hasMore
        }
        isLoading = false
    }

    private func loadOlderMessages() async {
        guard !isLoadingMore, let oldest = messages.first else { return }
        isLoadingMore = true
        if let socket = appState.socket {
            let result = (try? await socket.fetchOlderMessages(sessionId: sessionId, beforeSeq: oldest.seq, limit: 50)) ?? SocketClient.FetchResult(messages: [], hasMore: false)
            messages.insert(contentsOf: result.messages, at: 0)
            hasMoreOlder = result.hasMore
        }
        isLoadingMore = false
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        appState.sendMessage(text, toSession: sessionId)
        let msg = ChatMessage(id: UUID().uuidString, seq: (messages.last?.seq ?? 0) + 1, content: text, localId: nil)
        messages.append(msg)
    }
}

// MARK: - Message Row

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        let parsed = parseContent(message.content)

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: roleIcon(parsed.type))
                .font(.system(size: 10))
                .foregroundStyle(roleColor(parsed.type))
                .frame(width: 14, height: 14)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(roleLabel(parsed.type))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(roleColor(parsed.type))
                    .textCase(.uppercase)

                switch parsed.type {
                case "tool":
                    toolView(parsed)
                case "thinking":
                    thinkingView(parsed)
                case "interrupted":
                    Label(String(localized: "interrupted_by_user"), systemImage: "stop.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                default:
                    markdownContent(parsed.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    // MARK: - Markdown Rendering

    @ViewBuilder
    private func markdownContent(_ text: String) -> some View {
        let parts = splitCodeBlocks(text)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if part.isCode {
                    codeBlockView(part)
                } else if !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Use AttributedString for inline markdown
                    if let attributed = try? AttributedString(markdown: part.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attributed)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    } else {
                        Text(part.text)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func codeBlockView(_ part: TextPart) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !part.language.isEmpty {
                HStack {
                    Text(part.language)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = part.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(part.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Tool / Thinking Views

    private func toolView(_ parsed: ParsedMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: toolIcon(parsed.toolName ?? ""))
                    .font(.system(size: 10))
                Text(parsed.toolName ?? "tool")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let status = parsed.toolStatus {
                    Text(status)
                        .font(.system(size: 9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor(status).opacity(0.2), in: Capsule())
                        .foregroundStyle(statusColor(status))
                }
            }

            if !parsed.text.isEmpty {
                Text(parsed.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(8)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func thinkingView(_ parsed: ParsedMessage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "brain")
                .font(.system(size: 10))
            Text(parsed.text.isEmpty ? String(localized: "thinking_ellipsis") : parsed.text)
                .font(.caption)
                .italic()
                .lineLimit(3)
        }
        .foregroundStyle(.purple.opacity(0.8))
        .padding(6)
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Code Block Parsing

    private struct TextPart {
        let text: String
        let isCode: Bool
        let language: String
    }

    private func splitCodeBlocks(_ text: String) -> [TextPart] {
        var parts: [TextPart] = []
        let pattern = "```(\\w*)\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [TextPart(text: text, isCode: false, language: "")]
        }

        let nsText = text as NSString
        var lastEnd = 0
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            let beforeRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
            if beforeRange.length > 0 {
                parts.append(TextPart(text: nsText.substring(with: beforeRange), isCode: false, language: ""))
            }
            let lang = match.numberOfRanges > 1 ? nsText.substring(with: match.range(at: 1)) : ""
            let code = match.numberOfRanges > 2 ? nsText.substring(with: match.range(at: 2)) : ""
            parts.append(TextPart(text: code, isCode: true, language: lang))
            lastEnd = match.range.location + match.range.length
        }

        if lastEnd < nsText.length {
            parts.append(TextPart(text: nsText.substring(from: lastEnd), isCode: false, language: ""))
        }

        return parts.isEmpty ? [TextPart(text: text, isCode: false, language: "")] : parts
    }

    // MARK: - Parse

    private struct ParsedMessage {
        let type: String
        let text: String
        let toolName: String?
        let toolStatus: String?
    }

    private func parseContent(_ content: String) -> ParsedMessage {
        if let data = content.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = dict["type"] as? String {
            return ParsedMessage(type: type, text: dict["text"] as? String ?? "", toolName: dict["toolName"] as? String, toolStatus: dict["toolStatus"] as? String)
        }
        return ParsedMessage(type: "user", text: content, toolName: nil, toolStatus: nil)
    }

    // MARK: - Style Helpers

    private func roleColor(_ type: String) -> Color {
        switch type {
        case "user": return .blue
        case "assistant": return .green
        case "thinking": return .purple
        case "tool": return .cyan
        case "interrupted": return .red
        default: return .gray
        }
    }

    private func roleIcon(_ type: String) -> String {
        switch type {
        case "user": return "person.fill"
        case "assistant": return "sparkles"
        case "thinking": return "brain"
        case "tool": return "wrench.and.screwdriver.fill"
        case "interrupted": return "stop.circle.fill"
        default: return "circle"
        }
    }

    private func roleLabel(_ type: String) -> String {
        switch type {
        case "user": return String(localized: "role_you")
        case "assistant": return String(localized: "role_claude")
        case "thinking": return String(localized: "role_thinking")
        case "tool": return String(localized: "role_tool")
        case "interrupted": return String(localized: "role_interrupted")
        default: return type
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
        case "agent": return "person.2"
        case "task": return "checklist"
        default: return "gearshape"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "success", "completed": return .green
        case "error", "failed": return .red
        case "running", "pending": return .orange
        default: return .secondary
        }
    }
}
