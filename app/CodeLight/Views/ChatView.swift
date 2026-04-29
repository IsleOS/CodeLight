import SwiftUI
import PhotosUI

/// A pending image attachment in the compose bar (before send).
struct PendingAttachment: Identifiable {
    let id = UUID()
    let data: Data      // compressed JPEG, ready to upload
    let thumbnail: UIImage
}

/// Per-thumbnail upload progress tracked in ChatView.uploadStates.
enum UploadState: Equatable {
    case idle
    case uploading
    case done(blobId: String)
    case failed
}

/// Lifecycle of a message the user just sent. Used to fill the gap between
/// "user pressed send" and "Claude streams a real reply" — that gap can be
/// 2-5 seconds (server roundtrip + cmux paste + Claude warmup) and used to
/// look like a frozen UI to the user.
struct PendingSend: Equatable {
    enum Stage: Equatable {
        case sending     // emitting socket.message, waiting for ack
        case delivered   // server stored it, waiting for Claude to start
        case thinking    // Claude has emitted its first phase=thinking event
    }
    let localId: String
    let startedAt: Date
    var stage: Stage
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
    @State private var pendingSend: PendingSend? = nil
    @State private var inputText = ""
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var pickerSelections: [PhotosPickerItem] = []
    @State private var showPhotoLibrary = false
    @State private var showCamera = false
    @State private var isSending = false
    @State private var uploadStates: [UUID: UploadState] = [:]
    @State private var showSendWithoutImagesAlert = false
    @State private var pendingTextForAlert = ""
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
    @State private var isReadingScreen = false
    @State private var readScreenSentAt: Date? = nil
    @State private var scrollToBottomToken = UUID()
    @State private var turns: [ConversationTurn] = []
    /// True when the bottom sentinel is materialized in the LazyVStack
    /// render window — i.e. the user is at or near the bottom of the chat.
    /// Driven by onAppear/onDisappear on the chat-bottom sentinel below.
    /// When false, the user has scrolled up to read history and we hold
    /// our scroll position instead of yanking them back on every new message.
    @State private var isNearBottom: Bool = true
    /// Set when a new message arrives while the user is scrolled up.
    /// Shows the floating "↓ 新消息" pill so they can jump down on demand.
    @State private var hasUnreadBelow: Bool = false

    private let models = ["opus", "sonnet", "haiku"]
    private let modes = ["auto", "default", "plan"]

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

                        // Inline status footer that fills the dead air between
                        // "I just sent a message" and "Claude has streamed back
                        // any real content". Without this the user stares at a
                        // blank space for 2-5 seconds and starts to wonder if
                        // anything happened.
                        if let pending = pendingSend {
                            SendStatusFooter(stage: pending.stage)
                                .id("send-status")
                                .padding(.top, 6)
                        }

                        // Sentinel — always sits at the absolute bottom of the
                        // list so scrollTo("chat-bottom") reliably lands there
                        // regardless of how tall the last turn is.
                        // Doubles as a "near bottom" detector: LazyVStack
                        // materializes/un-materializes this row as it enters
                        // and exits the render window, which is roughly the
                        // viewport plus a screen of buffer in each direction.
                        // Good enough proxy for "user is following along" vs
                        // "user scrolled up to read history".
                        Color.clear.frame(height: 1).id("chat-bottom")
                            .onAppear {
                                isNearBottom = true
                                hasUnreadBelow = false
                            }
                            .onDisappear {
                                isNearBottom = false
                            }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                // Floating pill — only appears when the user is scrolled up
                // AND a new message arrived while they were away from the
                // bottom. Tap to jump back to the latest content. Without
                // this the smart-scroll change would silently swallow new
                // replies whenever the user is reading history.
                .overlay(alignment: .bottom) {
                    if hasUnreadBelow {
                        Button {
                            Haptics.light()
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("chat-bottom", anchor: .bottom)
                            }
                            hasUnreadBelow = false
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(String(localized: "new_messages_below", defaultValue: "新消息"))
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.brand, in: Capsule())
                            .foregroundStyle(Theme.onBrand)
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        }
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.25), value: hasUnreadBelow)
                // Update turns BEFORE the seq onChange reads turns.last.
                // SwiftUI fires modifiers in declaration order on the same view,
                // so placing this first guarantees turns is fresh when scroll logic runs.
                .onChange(of: messages) { _, _ in
                    turns = groupMessagesIntoTurns(messages)
                }
                .onChange(of: messages.last?.seq ?? 0) { oldSeq, newSeq in
                    // Auto-follow new messages so the latest reply is always
                    // visible — but only when the user is already at the
                    // bottom. If they've scrolled up to read history, hold
                    // the scroll position and instead flag hasUnreadBelow
                    // so the floating pill below can offer a tap-to-jump.
                    //
                    // Anchor to the persistent `chat-bottom` sentinel rather
                    // than the freshly appended message — the sentinel is
                    // already materialized so the scroll target always
                    // exists, dodging the "anchor on a row that hasn't laid
                    // out yet → land in dead space" glitch.
                    //
                    // Two-pass scroll because LazyVStack doesn't realize the
                    // newly appended rows synchronously: the first pass pulls
                    // the viewport in the right direction immediately so the
                    // motion feels responsive, the second pass after layout
                    // settles snaps to the true bottom in case the first
                    // pass landed slightly short.
                    guard shouldAutoScroll && newSeq > oldSeq else { return }
                    guard isNearBottom else {
                        hasUnreadBelow = true
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: pendingSend?.stage) { _, newStage in
                    // Don't re-scroll on stage transitions — the footer is
                    // already onscreen and re-animating it after every state
                    // change causes jitter. Only scroll once when the footer
                    // first appears (handled by the .onChange below).
                    _ = newStage
                }
                .onChange(of: pendingSend == nil) { _, _ in
                    // Footer appearing/disappearing — let the next layout pass
                    // settle and then nudge to keep the user's question visible.
                    guard let lastTurn = turns.last else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastTurn.anchorId, anchor: .top)
                        }
                    }
                }
                .onChange(of: scrollToBottomToken) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
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
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    Task { await forceRefresh() }
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)

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
        // PhotosPicker triggered from the attachment menu
        .photosPicker(
            isPresented: $showPhotoLibrary,
            selection: $pickerSelections,
            maxSelectionCount: 6,
            matching: .images
        )
        .onChange(of: pickerSelections) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                await loadPickedImages(newItems)
                await MainActor.run { pickerSelections = [] }
            }
        }
        // Camera sheet (fullScreenCover keeps the camera viewfinder immersive)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image { Task { await loadCapturedImage(image) } }
            }
            .ignoresSafeArea()
        }
        .task {
            await loadMessages()
            // Catch any messages that arrived during the HTTP roundtrip before
            // the socket finished connecting.
            scheduleDeltaFetch()
            startLiveActivity()
            // Scroll to the sentinel so the very bottom of the conversation is
            // visible on open, not just the top of the last turn.
            scrollToBottomToken = UUID()
        }
        .refreshable {
            await loadOlderMessages()
        }
        .onReceive(appState.newMessageSubject) { event in
            guard event.sessionId == sessionId else { return }
            // Phase / status messages are not chat content, but they're a useful
            // heartbeat: every Claude state change emits one. Use them as a signal
            // to delta-fetch any messages we may have missed via socket. They do
            // NOT enter the chat history (would cause LazyVStack scroll glitches).
            if isStatusOnly(event.message) {
                scheduleDeltaFetch()
                // While the user is waiting on a sent message, treat the next
                // thinking/tool_running phase as the "Claude is now working on
                // your prompt" signal and flip the status footer accordingly.
                if pendingSend != nil,
                   let phase = phaseFromMessage(event.message),
                   (phase == "thinking" || phase == "tool_running" || phase == "waiting_approval") {
                    if pendingSend?.stage != .thinking {
                        pendingSend?.stage = .thinking
                    }
                }
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
                // First real assistant reply after a send → clear the pending
                // status footer; the conversation can speak for itself now.
                if pendingSend != nil, messageType(event.message) == "assistant" {
                    pendingSend = nil
                }
            }
        }
        .onReceive(appState.messageUpdatedSubject) { event in
            guard event.sessionId == sessionId else { return }
            // In-place update for tool status changes (running→success)
            if let idx = messages.firstIndex(where: { $0.id == event.message.id }) {
                messages[idx] = event.message
            } else if let lid = event.message.localId,
                      let idx = messages.firstIndex(where: { $0.localId == lid }) {
                messages[idx] = event.message
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // App returned from background — socket was likely suspended by iOS,
            // so delta-fetch any messages we missed while backgrounded.
            scheduleDeltaFetch()
        }
        .onChange(of: appState.isConnected) { _, connected in
            // Socket just reconnected — fetch any messages missed while offline.
            // foreground notification fires before the socket is up, so this
            // second trigger is the one that actually succeeds.
            guard connected else { return }
            scheduleDeltaFetch()
        }
        .onDisappear {
            deltaFetchTask?.cancel()
            deltaFetchTask = nil
        }
        .alert(String(localized: "image_upload_all_failed_title"),
               isPresented: $showSendWithoutImagesAlert) {
            Button(String(localized: "image_send_text_only")) {
                sendTextOnly(pendingTextForAlert)
            }
            Button(String(localized: "cancel"), role: .cancel) {
                // User cancelled — clear failed states so thumbnails reset
                uploadStates = [:]
                isSending = false
            }
        } message: {
            Text(String(localized: "image_upload_all_failed_message"))
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

    /// Extract the `phase` field from a phase-type status message envelope.
    /// Returns nil for non-phase messages.
    private func phaseFromMessage(_ msg: ChatMessage) -> String? {
        guard let data = msg.content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (dict["type"] as? String) == "phase"
        else { return nil }
        return dict["phase"] as? String
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

                                // Upload state overlay
                                uploadStateOverlay(for: att)

                                // Dismiss button — hidden while uploading
                                if uploadStates[att.id] != .uploading {
                                    Button {
                                        pendingAttachments.removeAll { $0.id == att.id }
                                        uploadStates.removeValue(forKey: att.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white, .black.opacity(0.7))
                                    }
                                    .offset(x: 4, y: -4)
                                }
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
                    // Attachment menu — "Take Photo" (camera) or "Choose from Library"
                    // (PhotosPicker). Camera option is hidden on devices without a
                    // camera (simulator).
                    Menu {
                        if CameraPicker.isAvailable {
                            Button {
                                Haptics.medium()
                                showCamera = true
                            } label: {
                                Label(String(localized: "take_photo"), systemImage: "camera")
                            }
                        }
                        Button {
                            Haptics.medium()
                            showPhotoLibrary = true
                        } label: {
                            Label(String(localized: "choose_from_library"), systemImage: "photo.on.rectangle")
                        }
                    } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                    }

                    Button {
                        Haptics.light()
                        showCapabilitySheet = true
                    } label: {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 32, height: 32)
                    }

                    Button {
                        Haptics.light()
                        sendReadScreen()
                    } label: {
                        ZStack {
                            if isReadingScreen {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Theme.brand)
                            } else {
                                Image(systemName: "eye")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .frame(width: 32, height: 32)
                    }
                    .disabled(isReadingScreen)

                    Button {
                        Haptics.rigid()
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
                    Button {
                        Haptics.rigid()
                        send()
                    } label: {
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
            Rectangle().fill(Theme.divider).frame(height: 0.5),
            alignment: .top
        )
    }

    @ViewBuilder
    private func uploadStateOverlay(for att: PendingAttachment) -> some View {
        switch uploadStates[att.id] {
        case .uploading:
            ZStack {
                Color.black.opacity(0.45)
                ProgressView().controlSize(.small).tint(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .done:
            ZStack {
                Color.black.opacity(0.25)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.green)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .failed:
            ZStack {
                Color.red.opacity(0.55)
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        default:
            EmptyView()
        }
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

    /// Ask the Mac to snapshot the current cmux tab and ship the buffer back as a
    /// terminal_output message. Useful for verifying terminal state when something
    /// looks off on the phone timeline. Shows a spinner until we see a new message
    /// arrive or hit a 6s timeout.
    private func sendReadScreen() {
        guard !isReadingScreen else { return }
        let payload: [String: Any] = ["type": "read-screen"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        isReadingScreen = true
        readScreenSentAt = Date()
        let sentSeq = messages.last?.seq ?? 0
        appState.sendMessage(str, toSession: sessionId)
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if (messages.last?.seq ?? 0) > sentSeq { break }
            }
            isReadingScreen = false
            readScreenSentAt = nil
        }
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

    /// Stage a freshly-captured camera photo as an attachment.
    private func loadCapturedImage(_ image: UIImage) async {
        // JPEG-encode first (quality 0.92), then run through ImageCompressor for
        // downscaling + final compression — same pipeline as PhotosPicker images.
        guard let raw = image.jpegData(compressionQuality: 0.92),
              let compressed = ImageCompressor.compress(raw),
              let thumb = UIImage(data: compressed) else { return }
        let attachment = PendingAttachment(data: compressed, thumbnail: thumb)
        await MainActor.run {
            pendingAttachments.append(attachment)
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

    private func forceRefresh() async {
        messages = []
        turns = []
        hasMoreOlder = false
        await loadMessages()
        scheduleDeltaFetch()
        scrollToBottomToken = UUID()
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
            turns = groupMessagesIntoTurns(messages)
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

        // Lock the current last turn open. Otherwise the new message becomes
        // turns.last and the previous turn — which had been auto-expanded by
        // virtue of being last — silently collapses to a 1-line header. In a
        // long conversation that visual jump leaves the user staring at a
        // blank screen with their just-sent message scrolled out of view.
        if let prevLast = turns.last {
            expandedTurns.insert(prevLast.id)
        }

        // Light haptic — user gets immediate physical confirmation that the
        // tap was registered, even before any network round-trip.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        inputText = ""
        pendingAttachments = []
        isSending = true

        Task {
            // Upload blobs first — each thumbnail shows its own progress state.
            var blobIds: [String] = []
            if !attachmentsToSend.isEmpty, let socket = appState.socket {
                for att in attachmentsToSend {
                    await MainActor.run { uploadStates[att.id] = .uploading }
                    if let id = try? await socket.uploadBlob(data: att.data, mime: "image/jpeg") {
                        blobIds.append(id)
                        await MainActor.run {
                            uploadStates[att.id] = .done(blobId: id)
                            appState.addSentImage(att.data, forBlobId: id)
                        }
                    } else {
                        await MainActor.run { uploadStates[att.id] = .failed }
                    }
                }
            }

            // All images failed → show Alert, let user choose "send text only" or cancel.
            if !attachmentsToSend.isEmpty && blobIds.isEmpty {
                await MainActor.run {
                    isSending = false
                    pendingSend = nil
                    pendingTextForAlert = text
                    showSendWithoutImagesAlert = true
                }
                return
            }

            // Some failed but at least one succeeded — continue with uploaded images.
            // Failed thumbnails stay red so user can see which ones didn't make it.
            // Clear successful states after a brief moment.
            if !blobIds.isEmpty {
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run {
                        for att in attachmentsToSend {
                            if case .done = uploadStates[att.id] { uploadStates.removeValue(forKey: att.id) }
                        }
                    }
                }
            }

            // Compose payload. If there are blobs, send JSON; otherwise keep plain text so
            // MioIsland's existing "plain text = user message" path still works.
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
                // Mark this send as in flight so the UI can show a "Sending…"
                // → "Delivered" → "Claude is thinking" status footer beneath
                // the just-appended message.
                pendingSend = PendingSend(localId: localId, startedAt: Date(), stage: .sending)

                appState.sendMessage(payloadString, toSession: sessionId, localId: localId) {
                    // Server ack: the message landed in DB. Flip to "delivered".
                    if pendingSend?.localId == localId, pendingSend?.stage == .sending {
                        pendingSend?.stage = .delivered
                        // Medium haptic to confirm delivery
                        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
                    }
                }

                let msg = ChatMessage(id: "local-\(localId)",
                                      seq: (messages.last?.seq ?? 0) + 1,
                                      content: payloadString,
                                      localId: localId)
                messages.append(msg)
                isSending = false
                uploadStates = [:]
            }
        }
    }

    /// Called from the "Send text only" Alert when all image uploads failed.
    private func sendTextOnly(_ text: String) {
        uploadStates = [:]
        pendingAttachments = []
        guard !text.isEmpty, appState.socket != nil else { return }
        let localId = UUID().uuidString
        pendingSend = PendingSend(localId: localId, startedAt: Date(), stage: .sending)
        appState.sendMessage(text, toSession: sessionId, localId: localId) {
            if pendingSend?.localId == localId, pendingSend?.stage == .sending {
                pendingSend?.stage = .delivered
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
            }
        }
        let msg = ChatMessage(id: "local-\(localId)",
                              seq: (messages.last?.seq ?? 0) + 1,
                              content: text,
                              localId: localId)
        messages.append(msg)
    }
}


// Animations (PulseDot, ShimmerModifier, ThinkingDots) now live in
// ChatAnimations.swift.

// MARK: - Send Status Footer

/// Inline status row that lives at the bottom of ChatView while a sent
/// message is in flight. Bridges the dead air between "user pressed send"
/// and "Claude has streamed back any real content". Three stages:
///   - .sending     network round-trip in progress
///   - .delivered   server stored the message, Claude not yet engaged
///   - .thinking    Claude has emitted its first phase=thinking event
struct SendStatusFooter: View {
    let stage: PendingSend.Stage

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 18, height: 18)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(.easeInOut(duration: 0.2), value: stage)
    }

    @ViewBuilder
    private var iconView: some View {
        switch stage {
        case .sending:
            ProgressView()
                .controlSize(.small)
        case .delivered:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        case .thinking:
            ThinkingDots(color: .purple)
        }
    }

    private var label: String {
        switch stage {
        case .sending:   return String(localized: "send_status_sending")
        case .delivered: return String(localized: "send_status_delivered")
        case .thinking:  return String(localized: "send_status_thinking")
        }
    }
}
