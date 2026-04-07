import SwiftUI
import PhotosUI

/// A pending image attachment in the compose bar (before send).
struct PendingAttachment: Identifiable {
    let id = UUID()
    let data: Data      // compressed JPEG, ready to upload
    let thumbnail: UIImage
}

/// A conversation turn — user question + all Claude's responses until next user message.
struct ConversationTurn: Identifiable {
    let id: String          // Uses user message ID (or "initial" if no user msg)
    let userMessage: ChatMessage?
    let replies: [ChatMessage]
    let firstSeq: Int       // For sorting
    let questionText: String // For navigation
    let questionImageBlobIds: [String]   // For rendering attached images in the user bubble

    var anchorId: String { id }
}

/// Chat view with markdown rendering, lazy loading, and turn-based grouping.
struct ChatView: View {
    @EnvironmentObject var appState: AppState
    let sessionId: String

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var pickerSelections: [PhotosPickerItem] = []
    @State private var isSending = false
    @State private var showCapabilitySheet = false
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMoreOlder = false
    @State private var selectedModel = "opus"
    @State private var selectedMode = "auto"
    @State private var showQuestionNav = false
    @State private var expandedTurns = Set<String>()
    @State private var shouldAutoScroll = true
    @State private var lastSeenSeq: Int = 0
    @State private var deltaFetchTask: Task<Void, Never>? = nil

    private let models = ["opus", "sonnet", "haiku"]
    private let modes = ["auto", "default", "plan"]

    // Group messages into turns
    private var turns: [ConversationTurn] {
        groupMessagesIntoTurns(messages)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages grouped into turns with lazy loading
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
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
                                        .font(.system(size: 11, weight: .medium))
                                        .tracking(0.3)
                                        .foregroundStyle(Theme.brand)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 14)
                                        .background(Theme.brandSoft, in: Capsule())
                                        .overlay(Capsule().stroke(Theme.borderActive, lineWidth: 0.5))
                                }
                            }
                            .id("loadMore")
                        }

                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding()
                        }

                        ForEach(turns) { turn in
                            TurnView(turn: turn, isExpanded: isExpanded(turn), onToggle: { toggleTurn(turn) })
                                .id(turn.anchorId)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.last?.seq ?? 0) { oldSeq, newSeq in
                    // Only scroll to bottom when NEW messages arrive (seq increases),
                    // not when older messages are prepended.
                    guard shouldAutoScroll && newSeq > oldSeq else { return }
                    if let lastTurn = turns.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastTurn.anchorId, anchor: .bottom)
                        }
                    }
                }
                .sheet(isPresented: $showQuestionNav) {
                    QuestionNavSheet(
                        turns: turns,
                        isLoadingAll: isLoadingMore && hasMoreOlder
                    ) { turnId in
                        showQuestionNav = false
                        expandedTurns.insert(turnId)
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(turnId, anchor: .top)
                        }
                    }
                    .presentationDetents([.medium, .large])
                    .task {
                        // When the sheet appears, page through all older messages
                        // so the question list reflects the full session history.
                        await loadAllOlderMessages()
                    }
                }
            }

            Divider()

            // Input bar
            composeBar
        }
        .navigationTitle(sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showQuestionNav = true
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
            }
        }
        .sheet(isPresented: $showCapabilitySheet) {
            CapabilitySheet { text in
                if inputText.isEmpty {
                    inputText = text
                } else if inputText.hasSuffix(" ") {
                    inputText += text
                } else {
                    inputText += " " + text
                }
            }
        }
        .task {
            await loadMessages()
            startLiveActivity()
        }
        .refreshable {
            // Pull-down at top of chat = load older history (matches user mental model
            // for chat apps). New messages already arrive in real-time via socket, so
            // refreshing the latest is meaningless here.
            if hasMoreOlder { await loadOlderMessages() }
        }
        .onReceive(appState.newMessageSubject) { event in
            guard event.sessionId == sessionId else { return }
            // Phase / status messages are not chat content, but they're a useful
            // heartbeat: every Claude state change emits one. Use them as a signal
            // to delta-fetch any messages we may have missed via socket. They do
            // NOT enter the chat history (would cause LazyVStack scroll glitches).
            if isStatusOnly(event.message) {
                scheduleDeltaFetch()
                return
            }
            // Replace optimistic local message if server echoes back with same localId.
            if let lid = event.message.localId,
               let idx = messages.firstIndex(where: { $0.localId == lid }) {
                messages[idx] = event.message
                return
            }
            // Otherwise dedup by id and append.
            if !messages.contains(where: { $0.id == event.message.id }) {
                messages.append(event.message)
            }
        }
        .onDisappear {
            deltaFetchTask?.cancel()
            deltaFetchTask = nil
        }
    }

    // MARK: - Turn State

    private func isExpanded(_ turn: ConversationTurn) -> Bool {
        // The last turn is always expanded by default; others follow user toggle
        if turn.id == turns.last?.id { return true }
        return expandedTurns.contains(turn.id)
    }

    private func toggleTurn(_ turn: ConversationTurn) {
        if expandedTurns.contains(turn.id) {
            expandedTurns.remove(turn.id)
        } else {
            expandedTurns.insert(turn.id)
        }
    }

    // MARK: - Turn Grouping

    private func groupMessagesIntoTurns(_ messages: [ChatMessage]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var currentUserMsg: ChatMessage?
        var currentReplies: [ChatMessage] = []
        var currentFirstSeq: Int = 0
        var initialReplies: [ChatMessage] = []

        func flushCurrent() {
            if let user = currentUserMsg {
                let question = extractTextFromMessage(user)
                let blobIds = extractImageBlobIds(user)
                turns.append(ConversationTurn(
                    id: user.id,
                    userMessage: user,
                    replies: currentReplies,
                    firstSeq: currentFirstSeq,
                    questionText: question,
                    questionImageBlobIds: blobIds
                ))
            }
            currentUserMsg = nil
            currentReplies = []
        }

        for msg in messages {
            let type = messageType(msg)

            if type == "user" {
                flushCurrent()
                currentUserMsg = msg
                currentFirstSeq = msg.seq
            } else if currentUserMsg != nil {
                currentReplies.append(msg)
            } else {
                initialReplies.append(msg)
            }
        }
        flushCurrent()

        // Prepend initial replies (before first user message) if any
        if !initialReplies.isEmpty {
            turns.insert(ConversationTurn(
                id: "initial-\(initialReplies.first?.id ?? "")",
                userMessage: nil,
                replies: initialReplies,
                firstSeq: initialReplies.first?.seq ?? 0,
                questionText: String(localized: "session_start"),
                questionImageBlobIds: []
            ), at: 0)
        }

        return turns
    }

    private func messageType(_ msg: ChatMessage) -> String {
        if let data = msg.content.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = dict["type"] as? String {
            return type
        }
        return "user" // Plain text = user message from phone
    }

    private func extractTextFromMessage(_ msg: ChatMessage) -> String {
        if let data = msg.content.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = dict["text"] as? String {
            return text
        }
        return msg.content
    }

    private func extractImageBlobIds(_ msg: ChatMessage) -> [String] {
        guard let data = msg.content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = dict["images"] as? [[String: Any]]
        else { return [] }
        return images.compactMap { $0["blobId"] as? String }
    }

    private func startLiveActivity() {
        // Delay to ensure app is fully visible (fixes "visibility" error on launch)
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            await MainActor.run { doStartLiveActivity() }
        }
    }

    private func doStartLiveActivity() {
        // Delegate to AppState's global activity manager
        appState.startLiveActivitiesForActiveSessions()
    }

    // MARK: - Compose Bar

    private var composeBar: some View {
        VStack(spacing: 8) {
            // Attachment thumbnails
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { att in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: att.thumbnail)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Button {
                                    pendingAttachments.removeAll { $0.id == att.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 72)
            }

            HStack(spacing: 8) {
                // Left-side tool pill — three 32pt icon buttons, consistent size/weight.
                HStack(spacing: 2) {
                    PhotosPicker(
                        selection: $pickerSelections,
                        maxSelectionCount: 6,
                        matching: .images
                    ) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                    }
                    .onChange(of: pickerSelections) { _, newItems in
                        Task { await loadPickedImages(newItems) }
                    }

                    Button {
                        showCapabilitySheet = true
                    } label: {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 32, height: 32)
                    }

                    Button {
                        sendControlKey("escape")
                    } label: {
                        Image(systemName: "escape")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                    }
                }
                .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 0.5)
                )

                TextField(String(localized: "message_placeholder"), text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .foregroundStyle(Theme.textPrimary)
                    .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Theme.border, lineWidth: 0.5)
                    )
                    .lineLimit(1...5)

                // Send button only exists when there's something to send. Lime
                // filled circle with near-black icon for max contrast.
                if canSend || isSending {
                    Button { send() } label: {
                        ZStack {
                            Circle()
                                .fill(Theme.brand)
                                .frame(width: 32, height: 32)
                            if isSending {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Theme.onBrand)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Theme.onBrand)
                            }
                        }
                    }
                    .disabled(isSending)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: canSend)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Theme.bgPrimary)
        .overlay(
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    /// Send a control key (escape, enter, ctrl+c, …) to the session. Doesn't touch
    /// the input box — it's a fire-and-forget side channel.
    private func sendControlKey(_ key: String) {
        let payload: [String: Any] = ["type": "key", "key": key]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        appState.sendMessage(str, toSession: sessionId)
    }

    /// Read selected PhotosPicker items, compress, and stage them as attachments.
    private func loadPickedImages(_ items: [PhotosPickerItem]) async {
        var newAttachments: [PendingAttachment] = []
        for item in items {
            guard let raw = try? await item.loadTransferable(type: Data.self) else { continue }
            guard let compressed = ImageCompressor.compress(raw) else { continue }
            guard let thumb = UIImage(data: compressed) else { continue }
            newAttachments.append(PendingAttachment(data: compressed, thumbnail: thumb))
        }
        await MainActor.run {
            pendingAttachments.append(contentsOf: newAttachments)
            pickerSelections.removeAll()
        }
    }

    // MARK: - Data

    private var sessionTitle: String {
        appState.sessions.first { $0.id == sessionId }?.metadata?.displayProjectName ?? String(localized: "session")
    }

    /// Returns true if the message is a transient status update (phase/heartbeat)
    /// that should not appear in chat history. These are surfaced through the
    /// Live Activity instead.
    private func isStatusOnly(_ msg: ChatMessage) -> Bool {
        guard let data = msg.content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String else { return false }
        return type == "phase" || type == "heartbeat" || type == "key"
    }

    private func loadMessages() async {
        // Initial load only — never destructively replace once we have data.
        // New messages stream in via newMessageSubject; older ones come from the
        // explicit "Load earlier" button. This guard makes the function safe even
        // if SwiftUI re-runs the .task closure for any reason.
        guard messages.isEmpty else { return }
        isLoading = true
        if let socket = appState.socket {
            let result = (try? await socket.fetchMessages(sessionId: sessionId, limit: 50)) ?? SocketClient.FetchResult(messages: [], hasMore: false)
            messages = result.messages.filter { !isStatusOnly($0) }
            hasMoreOlder = result.hasMore
        }
        isLoading = false
    }

    private func loadOlderMessages() async {
        guard !isLoadingMore, let oldest = messages.first else { return }
        isLoadingMore = true
        if let socket = appState.socket {
            let result = (try? await socket.fetchOlderMessages(sessionId: sessionId, beforeSeq: oldest.seq, limit: 50)) ?? SocketClient.FetchResult(messages: [], hasMore: false)
            let filtered = result.messages.filter { !isStatusOnly($0) }
            messages.insert(contentsOf: filtered, at: 0)
            hasMoreOlder = result.hasMore
        }
        isLoadingMore = false
    }

    /// Page through every older batch until we've loaded the entire history.
    /// Used by the "Jump to question" sheet so users can navigate to questions
    /// that haven't been pulled into the visible window yet.
    private func loadAllOlderMessages() async {
        while hasMoreOlder && !Task.isCancelled {
            await loadOlderMessages()
        }
    }

    /// Debounced delta fetch — pulls any messages with seq > our current last
    /// seq from the server. Triggered by phase heartbeat messages so we self-heal
    /// from any dropped/missed real-time broadcasts (Claude responses are the
    /// main victim because they go through Mac's debounced JSONL parser).
    private func scheduleDeltaFetch() {
        deltaFetchTask?.cancel()
        deltaFetchTask = Task { [sessionId] in
            // Small debounce so a burst of phase events coalesces into one fetch.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let socket = appState.socket else { return }
            let afterSeq = messages.last?.seq ?? 0
            guard let result = try? await socket.fetchNewerMessages(sessionId: sessionId, afterSeq: afterSeq) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                for msg in result.messages {
                    if isStatusOnly(msg) { continue }
                    // Replace optimistic local row if localId matches.
                    if let lid = msg.localId,
                       let idx = messages.firstIndex(where: { $0.localId == lid }) {
                        messages[idx] = msg
                        continue
                    }
                    // Dedup by id.
                    if messages.contains(where: { $0.id == msg.id }) { continue }
                    messages.append(msg)
                }
            }
        }
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsToSend = pendingAttachments
        guard !text.isEmpty || !attachmentsToSend.isEmpty else { return }

        inputText = ""
        pendingAttachments = []
        isSending = true

        Task {
            // Upload blobs first (if any), keeping the raw data in a local cache so
            // MessageRow can render the image immediately in history.
            var blobIds: [String] = []
            if !attachmentsToSend.isEmpty, let socket = appState.socket {
                for att in attachmentsToSend {
                    if let id = try? await socket.uploadBlob(data: att.data, mime: "image/jpeg") {
                        blobIds.append(id)
                        await MainActor.run { appState.sentImageCache[id] = att.data }
                    }
                }
            }

            // Compose payload. If there are blobs, send JSON; otherwise keep plain text so
            // CodeIsland's existing "plain text = user message" path still works.
            let payloadString: String
            if !blobIds.isEmpty {
                var payload: [String: Any] = ["type": "user", "text": text]
                payload["images"] = blobIds.map { ["blobId": $0, "mime": "image/jpeg"] }
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let str = String(data: data, encoding: .utf8) {
                    payloadString = str
                } else {
                    payloadString = text
                }
            } else {
                payloadString = text
            }

            // Share one localId between the socket emit and the optimistic
            // ChatMessage so the server echo can replace the local row instead
            // of producing a duplicate.
            let localId = UUID().uuidString
            await MainActor.run {
                appState.sendMessage(payloadString, toSession: sessionId, localId: localId)
                let msg = ChatMessage(id: "local-\(localId)",
                                      seq: (messages.last?.seq ?? 0) + 1,
                                      content: payloadString,
                                      localId: localId)
                messages.append(msg)
                isSending = false
            }
        }
    }
}


// Animations (PulseDot, ShimmerModifier, ThinkingDots) now live in
// ChatAnimations.swift.
