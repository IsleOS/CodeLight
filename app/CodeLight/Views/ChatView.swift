import SwiftUI

/// Chat view for a single session — shows messages and allows sending.
struct ChatView: View {
    @EnvironmentObject var appState: AppState
    let sessionId: String

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = true
    @State private var selectedModel = "opus"
    @State private var selectedMode = "auto"

    private let models = ["opus", "sonnet", "haiku"]
    private let modes = ["auto", "default", "plan"]

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
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
                    .padding()
                }
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Model/Mode selector + Input
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Menu {
                        ForEach(models, id: \.self) { model in
                            Button(model.capitalized) { selectedModel = model }
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
                            Button(mode.capitalized) { selectedMode = mode }
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
                    TextField("Message...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .lineLimit(1...5)

                    Button {
                        send()
                    } label: {
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
        .navigationTitle(sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadMessages()
        }
        .refreshable {
            await loadMessages()
        }
        .onReceive(appState.newMessageSubject) { event in
            guard event.sessionId == sessionId else { return }
            // Avoid duplicates
            if !messages.contains(where: { $0.id == event.message.id }) {
                messages.append(event.message)
            }
        }
    }

    private var sessionTitle: String {
        appState.sessions.first { $0.id == sessionId }?.metadata?.title ?? "Session"
    }

    private func loadMessages() async {
        isLoading = true
        if let socket = appState.socket {
            messages = (try? await socket.fetchMessages(sessionId: sessionId)) ?? []
            print("[ChatView] Loaded \(messages.count) messages")
        }
        isLoading = false
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
            // Role indicator
            Circle()
                .fill(roleColor(parsed.type))
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                // Role label
                Text(roleLabel(parsed.type))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(roleColor(parsed.type))

                // Content
                if parsed.type == "tool" {
                    toolView(parsed)
                } else {
                    Text(parsed.text)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func toolView(_ parsed: ParsedMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "wrench.fill")
                    .font(.caption2)
                Text(parsed.toolName ?? "tool")
                    .font(.caption)
                    .fontWeight(.medium)
                if let status = parsed.toolStatus {
                    Text("· \(status)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.cyan)

            if !parsed.text.isEmpty {
                Text(parsed.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(8)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Parse

    private struct ParsedMessage {
        let type: String
        let text: String
        let toolName: String?
        let toolStatus: String?
    }

    private func parseContent(_ content: String) -> ParsedMessage {
        // Try parsing as JSON (messages from CodeIsland)
        if let data = content.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = dict["type"] as? String {
            let text = dict["text"] as? String ?? ""
            let toolName = dict["toolName"] as? String
            let toolStatus = dict["toolStatus"] as? String
            return ParsedMessage(type: type, text: text, toolName: toolName, toolStatus: toolStatus)
        }

        // Plain text (user messages from phone)
        return ParsedMessage(type: "user", text: content, toolName: nil, toolStatus: nil)
    }

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

    private func roleLabel(_ type: String) -> String {
        switch type {
        case "user": return "You"
        case "assistant": return "Claude"
        case "thinking": return "Thinking"
        case "tool": return "Tool"
        case "interrupted": return "Interrupted"
        default: return type
        }
    }
}
