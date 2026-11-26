import AppKit
import OmnisCore
import SwiftUI

/// The chat window: a header you can drag, the conversation, and the input bar.
struct ChatView: View {
    @ObservedObject var model: ChatModel
    let onClose: () -> Void
    /// Moves the conversation to the dashboard, where there is room. Only the small window has this.
    var onExpand: (() -> Void)?
    /// True when shown inside the dashboard rather than in the small window of its own.
    var embedded = false
    @FocusState private var inputFocused: Bool
    @State private var showModel = false
    @State private var showEffort = false
    @State private var dropTargeted = false

    static let corner: CGFloat = 26
    private static let bottomID = "bottom"

    /// The widest the conversation is laid out in the dashboard, for lines that are comfortable to read.
    private static let column: CGFloat = 760
    @AppStorage("OMNISChatSidebar") private var showSidebar = true
    @State private var showHistory = false

    var body: some View {
        Group {
            if embedded {
                // In the dashboard: saved chats on the left, the conversation in a readable column beside them.
                HStack(spacing: 14) {
                    if showSidebar, model.keepsChats {
                        ChatSidebar(model: model).frame(width: 272).transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    VStack(spacing: 0) {
                        embeddedHeader
                        Rectangle().fill(Ink.line).frame(height: 1)
                        conversation
                        inputBar.frame(maxWidth: Self.column + 24).padding(.bottom, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Ink.panel))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.line))
                }
                .environment(\.chatAccent, Ink.gold)
                .environment(\.chatOnAccent, Ink.ground)
                .environment(\.chatEmbedded, true)
                .tint(Ink.gold)
            } else {
                VStack(spacing: 0) {
                    header
                    conversation
                    inputBar
                }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
                .ignoresSafeArea()
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .strokeBorder(accent, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.attach(urls: [url]) }
                }
            }
            return !providers.isEmpty
        }
        .onChange(of: model.openCount) { focusInput() }
        .onAppear { focusInput() }
    }

    private var accent: Color { embedded ? Ink.gold : .accentColor }

    private func focusInput() {
        DispatchQueue.main.async { inputFocused = true }
    }

    // MARK: Header

    /// The small window's header: close, expand, earlier chats, usage, new chat.
    private var header: some View {
        ZStack {
            // The whole strip moves the window; the buttons sit on top of it.
            WindowDragArea()
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                }
                .help("Hide OMNIS (Esc)")
                .accessibilityLabel("Hide OMNIS")
                if let onExpand {
                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14, weight: .medium))
                    }
                    .help("Open this chat in the dashboard")
                    .accessibilityLabel("Open this chat in the dashboard")
                }
                Spacer()
                if model.usesLocal {
                    Label("On this Mac", systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .medium))
                        .help("Questions are being answered by the model on this Mac. Nothing is sent to Claude.")
                        .accessibilityLabel("Answering on this Mac")
                } else if let usage = model.usageLabel {
                    // How much of your Claude plan is used: the current five hours, and this week.
                    Text(usage)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(model.usageIsHigh ? Color.orange : Color.secondary)
                        .help("How much of your Claude plan has been used: the current five-hour window and this week. OMNIS stops using Claude at 80% and 70%.")
                        .accessibilityLabel("Claude usage: \(usage)")
                }
                if model.keepsChats {
                    Button { showHistory.toggle() } label: {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 15, weight: .medium))
                    }
                    .help("Earlier chats")
                    .accessibilityLabel("Earlier chats")
                    .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                        ChatSidebar(model: model, compact: true, onOpen: { showHistory = false })
                            .frame(width: 300, height: 400)
                            .background(Ink.lift)
                            .preferredColorScheme(.dark)
                    }
                }
                Button(action: model.newChat) {
                    Image(systemName: "square.and.pencil").font(.system(size: 16, weight: .medium))
                }
                .help("New chat")
                .accessibilityLabel("New chat")
                .disabled(model.conversation.isEmpty)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
        }
        .frame(height: 40)
    }

    /// The dashboard's header: the chat's name, whether it is being saved, and the way back to the small window.
    private var embeddedHeader: some View {
        HStack(spacing: 10) {
            if model.keepsChats {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { showSidebar.toggle() }
                } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .help(showSidebar ? "Hide the list of chats" : "Show the list of chats")
                .accessibilityLabel(showSidebar ? "Hide the list of chats" : "Show the list of chats")
            }
            Text(model.chatTitle ?? "New chat")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if model.usesLocal {
                HeaderChip(symbol: "lock.fill", text: "On this Mac", colour: Ink.data)
                    .help("Questions are being answered by the model on this Mac. Nothing is sent to Claude.")
            }
            Spacer(minLength: 12)
            if model.keepsChats {
                Button { model.isPrivate.toggle() } label: {
                    HeaderChip(symbol: model.isPrivate ? "eye.slash.fill" : "internaldrive",
                               text: model.isPrivate ? "Not saved" : "Saved on this Mac",
                               colour: model.isPrivate ? Ink.gold : Ink.faint)
                }
                .help(model.isPrivate ? "This chat is not being saved, and nothing of it is on disk. Click to save it."
                                      : "This chat is saved on this Mac so you can come back to it. Click to stop saving it and remove what was saved.")
                .accessibilityLabel(model.isPrivate ? "This chat is not saved" : "This chat is saved on this Mac")
                .accessibilityHint("Switches saving for this chat")
            }
            if !showSidebar || !model.keepsChats {
                Button(action: model.newChat) {
                    Image(systemName: "square.and.pencil").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .help("New chat").accessibilityLabel("New chat").disabled(model.conversation.isEmpty)
            }
            Button(action: onClose) {
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help("Carry on in the small window")
            .accessibilityLabel("Move this chat to the small window")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.muted)
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    // MARK: Conversation

    @ViewBuilder private var conversation: some View {
        if embedded, model.conversation.isEmpty {
            welcome
        } else {
            messages
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: embedded ? 22 : 18) {
                    if model.conversation.isEmpty {
                        emptyState
                    }
                    ForEach(model.conversation.messages) { message in
                        MessageView(message: message, open: model.open, confirm: model.confirm, decline: model.decline,
                                    answerLocally: model.answerLocally, answerSearch: model.answerSearchAsk, confirmProject: model.confirmProject,
                                    declineProject: model.declineProject, openInProjectMode: model.openInProjectMode,
                                    confirmAction: model.confirmAction, declineAction: model.declineAction)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, embedded ? 24 : 18)
                .padding(.top, embedded ? 22 : 4)
                .padding(.bottom, 10)
                .frame(maxWidth: embedded ? Self.column + 48 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.conversation) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            // A chat opened from the list starts at its latest message.
            .onChange(of: model.chatID) {
                DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text("Ask a question, or type the name of an app or project to open it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 30)
        .accessibilityElement(children: .combine)
    }

    /// The dashboard's empty chat: a greeting and a few places to start.
    private var welcome: some View {
        VStack(spacing: 26) {
            HaloMark().frame(width: 54, height: 54).accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(DashboardData.greeting(now: Date())).font(.system(size: 28, weight: .medium)).foregroundStyle(Ink.text)
                Text(model.isPrivate ? "This chat will not be saved." : "Ask anything, or start with one of these.")
                    .font(.system(size: 14)).foregroundStyle(Ink.muted)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Starter.all) { starter in
                    StarterCard(starter: starter) { model.ask(suggestion: starter.prompt) }
                }
            }
            .frame(maxWidth: 560)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(spacing: 6) {
            if !model.suggestions.isEmpty {
                suggestionStrip
            }
            VStack(alignment: .leading, spacing: 10) {
                if !model.pendingAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.pendingAttachments) { attachment in
                                AttachmentChip(attachment: attachment) { model.removeAttachment(attachment.id) }
                            }
                        }
                    }
                }
                TextField("Ask OMNIS", text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit { model.submit() }
                    .accessibilityLabel("Message to OMNIS")
                controls
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(embedded ? 0.055 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(embedded && inputFocused ? Ink.gold.opacity(0.38) : Color.primary.opacity(0.10))
            )
            .animation(.easeOut(duration: 0.15), value: inputFocused)
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var suggestionStrip: some View {
        VStack(spacing: 2) {
            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, entry in
                SuggestionRow(entry: entry, editorName: model.editorName, selected: index == model.selectedSuggestion)
                    .contentShape(Rectangle())
                    .onTapGesture { model.launch(entry) }
                    .accessibilityAction { model.launch(entry) }
            }
            Text(model.selectedSuggestion == nil
                 ? "Press \u{2191} to choose one, or Return to send as a message"
                 : "Return opens it. Press \u{2193} to send as a message instead")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 2)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button(action: model.chooseFiles) {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .help("Attach an image, PDF or text file. You can also drag one in, or paste a screenshot.")
            .accessibilityLabel("Attach a file")

            if model.webBlockedByFile {
                // A chat that has had a file never searches. Say so, where the
                // control is, instead of showing a switch that does nothing.
                Label("Web off in this chat", systemImage: "globe.badge.chevron.backward")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .help("Web search is off in a chat that holds a file or your calendar, so none of it can end up in a search. Start a new chat to search the web.")
                    .accessibilityLabel("Web search is off in this chat because it holds personal information")
            } else {
                Button {
                    model.webEnabled.toggle()
                } label: {
                    Label(model.webEnabled ? "Web on" : "Web off", systemImage: model.webEnabled ? "globe" : "globe.badge.chevron.backward")
                        .labelStyle(.titleAndIcon)
                }
                .foregroundStyle(model.webEnabled ? accent : Color.secondary)
                .help(model.webEnabled ? "OMNIS may search the web when a question needs it. Click to turn off."
                                       : "Web search is off. Click to turn on.")
                .accessibilityLabel(model.webEnabled ? "Web search on" : "Web search off")
            }

            SettingPill(name: "Model", value: model.usesLocal ? "Local" : model.modelChoice.title, isOpen: $showModel) {
                StepSlider(title: "Model", choices: ModelChoice.allCases.map(\.title),
                           index: Binding(get: { ModelChoice.allCases.firstIndex(of: model.modelChoice) ?? 0 },
                                          set: { model.modelChoice = ModelChoice.allCases[$0] }),
                           note: "Auto uses Haiku for ordinary questions and Sonnet for harder ones.")
                    .disabled(model.usesLocal)
                Divider()
                Toggle(isOn: $model.offGrid) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Off the grid").font(.system(size: 12, weight: .medium))
                        Text("Answer on this Mac. Nothing is sent to Claude.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .help("Which Claude model answers. You can also type /model sonnet, or /local on.")

            SettingPill(name: "Effort", value: model.usesLocal ? "\u{2013}" : model.effortChoice.title, isOpen: $showEffort) {
                StepSlider(title: "Effort", choices: EffortChoice.allCases.map(\.title),
                           index: Binding(get: { EffortChoice.allCases.firstIndex(of: model.effortChoice) ?? 0 },
                                          set: { model.effortChoice = EffortChoice.allCases[$0] }),
                           note: "How hard the model thinks. Higher is slower and uses more of your plan.")
                    .disabled(model.usesLocal)
            }
            .help("How hard the model thinks. You can also type /effort high.")

            Spacer()

            if model.isAnswering {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 26))
                }
                .foregroundStyle(.primary)
                .help("Stop answering")
                .accessibilityLabel("Stop answering")
            } else {
                Button(action: model.send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                }
                .foregroundStyle(model.canSend ? accent : Color.secondary.opacity(0.5))
                .disabled(!model.canSend)
                .help("Send")
                .accessibilityLabel("Send")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
    }
}

// MARK: - Messages

private struct MessageView: View {
    let message: ChatMessage
    let open: (SearchResult) -> Void
    let confirm: (UUID) -> Void
    let decline: (UUID) -> Void
    let answerLocally: (UUID) -> Void
    let answerSearch: (Bool) -> Void
    let confirmProject: (UUID) -> Void
    let declineProject: (UUID) -> Void
    let openInProjectMode: (UUID) -> Void
    let confirmAction: (UUID) -> Void
    let declineAction: (UUID) -> Void
    @Environment(\.chatAccent) private var accent
    @Environment(\.chatEmbedded) private var embedded

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: embedded ? 120 : 40)
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        AttachmentChip(attachment: attachment, onRemove: nil)
                    }
                    // In a chat opened again, a file is shown by name: the file itself was not saved.
                    ForEach(message.archivedNotes, id: \.self) { note in
                        Label(note.replacingOccurrences(of: "Attached: ", with: ""), systemImage: "paperclip")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .help(Conversation.fileNote)
                            .accessibilityLabel("\(note). \(Conversation.fileNote)")
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 15))
                            .foregroundStyle(embedded ? Ink.text : .white)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(embedded ? Color.white.opacity(0.085) : Color.accentColor))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(embedded ? Color.white.opacity(0.07) : Color.clear))
                            .accessibilityLabel("You said: \(message.text)")
                    }
                }
            }
        case .assistant:
            answer
        }
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.text.isEmpty {
                AnswerText(text: message.text)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("OMNIS said: \(message.text)")
            }
            if case .failed(let reason) = message.state {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if message.offersLocal {
                Button("Answer on this Mac instead") { answerLocally(message.id) }
                    .controlSize(.small)
                    .help("Use the model on this Mac for this question and the rest of this chat.")
            }
            if let ask = message.searchAsk {
                SearchAskCard(ask: ask, allow: { answerSearch(true) }, decline: { answerSearch(false) })
            }
            ForEach(message.actions) { action in
                ActionCard(action: action, confirm: { confirmAction(action.id) }, decline: { declineAction(action.id) })
            }
            if !message.serviceNotes.isEmpty {
                // Shown so you can always see which of your services were used.
                Text(message.serviceNotes.joined(separator: " \u{00B7} "))
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
            }
            ForEach(message.projects) { proposal in
                ProjectCard(proposal: proposal, confirm: { confirmProject(proposal.id) }, decline: { declineProject(proposal.id) },
                            openInProjectMode: { openInProjectMode(proposal.id) })
            }
            ForEach(message.proposals) { proposal in
                EventCard(proposal: proposal, confirm: { confirm(proposal.id) }, decline: { decline(proposal.id) })
            }
            if let problem = message.proposalProblem {
                Label(problem.prefix(1).uppercased() + problem.dropFirst(), systemImage: "calendar.badge.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let problem = message.calendarProblem {
                Label("Could not read your calendar: \(problem)", systemImage: "calendar.badge.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !message.calendarNotes.isEmpty {
                // Shown so you can always see when your calendar was read, and for which days.
                Label("Read your calendar for " + message.calendarNotes.joined(separator: "; "), systemImage: "calendar")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            if let problem = message.searchProblem {
                Label("Could not search the web: \(problem)", systemImage: "wifi.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if !message.sources.isEmpty {
                sources
            }
            ForEach(message.archivedNotes, id: \.self) { note in
                // From a chat opened again: what was read or prepared then, as words only.
                Label(note, systemImage: note == Conversation.withheldNote ? "envelope" : "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            status
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var status: some View {
        switch message.state {
        case .streaming:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message.readingCalendar ? "Checking your calendar"
                     : message.searching ? "Searching the web for \u{201C}\(message.searchQueries.last ?? "")\u{201D}"
                     : message.text.isEmpty ? "Thinking" : "Answering")
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        case .stopped:
            HStack(spacing: 8) {
                Text("Stopped").font(.system(size: 11)).foregroundStyle(.tertiary)
                if !message.text.isEmpty { CopyButton(text: message.text) }
            }
        case .done:
            HStack(spacing: 8) {
                if let line = message.sourceLine {
                    Text(line).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                if !message.text.isEmpty { CopyButton(text: message.text) }
            }
        case .failed:
            EmptyView()
        }
    }

    /// The pages the model was given. These are the only links in the window:
    /// they come from the search results, not from the model's own text.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Sources").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if !message.searchQueries.isEmpty {
                // Shown so you can always see what was sent to the search engines.
                Text("Searched for: " + message.searchQueries.joined(separator: "; "))
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
            }
            ForEach(Array(message.sources.enumerated()), id: \.element.id) { index, source in
                Button {
                    open(source)
                } label: {
                    HStack(spacing: 6) {
                        Text("[\(index + 1)]").monospacedDigit().foregroundStyle(.secondary)
                        Text(source.title).lineLimit(1).truncationMode(.tail)
                        Text(source.host).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(source.url.absoluteString)
                .accessibilityLabel("Source \(index + 1): \(source.title), \(source.host). Opens in your browser.")
            }
        }
    }
}

/// A change from one of the services, shown for the user to check. Nothing
/// is done until the confirm button is clicked.
private struct ActionCard: View {
    @Environment(\.chatAccent) private var accent
    let action: ActionProposal
    let confirm: () -> Void
    let decline: () -> Void

    private var isLive: Bool { action.state == .waiting || action.state == .saving }
    private var symbol: String {
        switch action.service {
        case "reminders": return action.destructive ? "trash" : "checklist"
        case "mail": return "envelope"
        case "messages": return "message"
        default: return "square.and.pencil"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18))
                    .foregroundStyle(!isLive ? Color.secondary : action.destructive ? Color.red : accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.heading.uppercased()).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(action.destructive && isLive ? Color.red : Color.secondary)
                    Text(action.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(action.rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(row.label).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                            // A message to be sent is always shown whole; other long notes are cut.
                            Text(row.value).lineLimit(row.label == "Notes" || (row.label == "Message" && action.kind != "send_message") ? 12 : nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                    }
                    if isLive, let warning = action.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(action.destructive ? .red : .orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            footer
        }
        .padding(12)
        .frame(maxWidth: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(action.heading): \(action.title)")
    }

    @ViewBuilder private var footer: some View {
        switch action.state {
        case .waiting:
            HStack(spacing: 8) {
                Text("Nothing changed yet").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button(action.declineLabel, action: decline)
                if action.destructive {
                    Button(action.confirmLabel, role: .destructive, action: confirm).buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button(action.confirmLabel, action: confirm).buttonStyle(ConfirmStyle())
                }
            }
            .controlSize(.small)
        case .saving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Working").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .done(let result):
            Label(result, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
        case .declined:
            Text("Not done").font(.system(size: 12)).foregroundStyle(.secondary)
        case .replaced:
            Text("Not done. Replaced by a newer preview below.").font(.system(size: 12)).foregroundStyle(.secondary)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 6) {
                Label("Not done: \(why)", systemImage: "exclamationmark.triangle.fill").font(.system(size: 12))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if action.kind == "send_message" {
                    // Trying again could send it twice if it went after all.
                    Text("Look in Messages before asking again.").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button(action.declineLabel, action: decline)
                        Button("Try Again", action: confirm)
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

/// Asks, once per chat, whether a chat that holds personal information may
/// search outside. Built to match the other preview cards.
private struct SearchAskCard: View {
    @Environment(\.chatAccent) private var accent
    let ask: SearchAsk
    let allow: () -> Void
    let decline: () -> Void

    private var isLive: Bool { ask.state == .waiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "globe").font(.system(size: 18))
                    .foregroundStyle(isLive ? accent : Color.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text("WEB SEARCH").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Text("Allow web searches in this chat?").font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("This chat holds personal information, and a search sends words to search engines. You are asked once per chat.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !ask.query.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("First search").foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
                            Text(ask.query).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                    }
                }
                Spacer(minLength: 0)
            }
            footer
        }
        .padding(12)
        .frame(maxWidth: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Allow web searches in this chat?")
    }

    @ViewBuilder private var footer: some View {
        switch ask.state {
        case .waiting:
            HStack(spacing: 8) {
                Text("Nothing searched yet").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("Don\u{2019}t Search", action: decline)
                Button("Allow in This Chat", action: allow).buttonStyle(ConfirmStyle())
            }
            .controlSize(.small)
        case .allowed:
            Label("Searches allowed for the rest of this chat", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(.green)
        case .declined:
            Text("No searches in this chat. Start a new chat to search.").font(.system(size: 12)).foregroundStyle(.secondary)
        case .lapsed:
            Text("Not answered, so nothing was searched. You will be asked again.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// A new project, shown for the user to check. Nothing is created until the button is clicked.
private struct ProjectCard: View {
    @Environment(\.chatAccent) private var accent
    let proposal: ProjectProposal
    let confirm: () -> Void
    let decline: () -> Void
    let openInProjectMode: () -> Void

    private var isLive: Bool { proposal.state == .waiting || proposal.state == .saving }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "folder.badge.plus").font(.system(size: 18))
                    .foregroundStyle(isLive ? accent : Color.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text("NEW PROJECT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Text(proposal.plan.name).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(proposal.plan.rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(row.label).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                            Text(row.value).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                    }
                    if isLive, let warning = proposal.plan.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            footer
        }
        .padding(12)
        .frame(maxWidth: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New project: \(proposal.plan.name)")
    }

    @ViewBuilder private var footer: some View {
        switch proposal.state {
        case .waiting:
            HStack(spacing: 8) {
                Text("Nothing created yet").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("Don't Create", action: decline)
                Button("Create Project", action: confirm).buttonStyle(ConfirmStyle())
            }
            .controlSize(.small)
        case .saving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(proposal.progress ?? "Working").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .done(let result):
            VStack(alignment: .leading, spacing: 6) {
                Label(result, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open in Project Mode", action: openInProjectMode).controlSize(.small)
                    .help("Shows this project in the dashboard's Project view, ready for a Claude Code session.")
            }
        case .declined:
            Text("Not created").font(.system(size: 12)).foregroundStyle(.secondary)
        case .replaced:
            Text("Not created. Replaced by a newer preview below.").font(.system(size: 12)).foregroundStyle(.secondary)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A small label in the input bar showing one setting. Clicking it opens a slider above it.
private struct SettingPill<Content: View>: View {
    let name: String
    let value: String
    @Binding var isOpen: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(name).foregroundStyle(.tertiary)
                Text(value).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(isOpen ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("\(name): \(value)")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(width: 280)
        }
    }
}

/// A slider that snaps to a few named positions.
private struct StepSlider: View {
    let title: String
    let choices: [String]
    @Binding var index: Int
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(choices.indices.contains(index) ? choices[index] : "").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(index) }, set: { index = Int($0.rounded()) }),
                   in: 0...Double(max(choices.count - 1, 1)), step: 1)
                .accessibilityLabel(title)
                .accessibilityValue(choices.indices.contains(index) ? choices[index] : "")
            HStack(spacing: 0) {
                ForEach(Array(choices.enumerated()), id: \.offset) { position, choice in
                    Text(choice)
                        .font(.system(size: 10, weight: position == index ? .semibold : .regular))
                        .foregroundStyle(position == index ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: position == 0 ? .leading : position == choices.count - 1 ? .trailing : .center)
                        .contentShape(Rectangle())
                        .onTapGesture { index = position }
                }
            }
            Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One change to the calendar, shown for the user to check. Nothing is
/// done until the confirm button is clicked.
private struct EventCard: View {
    @Environment(\.chatAccent) private var accent
    let proposal: EventProposal
    let confirm: () -> Void
    let decline: () -> Void

    private var change: CalendarChange { proposal.change }
    private var isLive: Bool { proposal.state == .waiting || proposal.state == .saving }

    private var symbol: String {
        switch change {
        case .create: return "calendar.badge.plus"
        case .update: return "calendar.badge.clock"
        case .delete: return "calendar.badge.minus"
        case .createCalendar: return "plus.rectangle.on.rectangle"
        case .renameCalendar: return "pencil"
        case .deleteCalendar: return "trash"
        }
    }

    private var rows: [ChangeRow] {
        var rows = change.rows()
        // A new event with no calendar named goes to the default one.
        if case .create(let draft) = change, draft.calendarName == nil, isLive {
            rows.append(ChangeRow("Calendar", proposal.calendarName ?? "your default calendar"))
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(!isLive ? Color.secondary : change.isDestructive ? Color.red : accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(change.heading.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(change.isDestructive && isLive ? Color.red : Color.secondary)
                    // Shown in full: what you see is exactly what is done.
                    Text(change.title)
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .leading)
                            // Notes can be long; they are cut after a few lines
                            // here so the buttons stay in view.
                            Text(row.value)
                                .lineLimit(row.label == "Notes" ? 8 : nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                    }
                    if isLive, let start = change.resultingStart, start < Date() {
                        Label("This time is in the past", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                    if isLive, let warning = change.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            footer
        }
        .padding(12)
        .frame(maxWidth: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(change.heading): \(change.title)")
    }

    @ViewBuilder private var confirmButton: some View {
        if change.isDestructive {
            Button(change.confirmLabel, role: .destructive, action: confirm)
                .buttonStyle(.borderedProminent)
                .tint(.red)
        } else {
            Button(change.confirmLabel, action: confirm)
                .buttonStyle(ConfirmStyle())
        }
    }

    @ViewBuilder private var footer: some View {
        switch proposal.state {
        case .waiting:
            HStack(spacing: 8) {
                Text("Nothing changed yet").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button(change.declineLabel, action: decline)
                confirmButton
            }
            .controlSize(.small)
        case .saving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Working").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .done(let result):
            Label(result, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(.green)
        case .declined:
            Text("Not done").font(.system(size: 12)).foregroundStyle(.secondary)
        case .replaced:
            Text("Not done. Replaced by a newer preview below.").font(.system(size: 12)).foregroundStyle(.secondary)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 6) {
                Label("Not done: \(why)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(change.declineLabel, action: decline)
                    Button("Try Again", action: confirm)
                }
                .controlSize(.small)
            }
        }
    }
}

/// An answer laid out as headings, lists, code and paragraphs.
private struct AnswerText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(AnswerBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: AnswerBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(AnswerFormatter.format(text))
                .font(.system(size: level <= 2 ? 17 : 15, weight: .semibold))
                .padding(.top, 2)
        case .paragraph(let text):
            Text(AnswerFormatter.format(text)).font(.system(size: 15)).lineSpacing(3)
        case .bullet(let text):
            listRow(marker: "\u{2022}", text: text)
        case .numbered(let number, let text):
            listRow(marker: "\(number).", text: text)
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(size: 13, design: .monospaced)).padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.08)))
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker).font(.system(size: 15)).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            Text(AnswerFormatter.format(text)).font(.system(size: 15)).lineSpacing(3)
        }
    }
}

private struct SuggestionRow: View {
    let entry: RegistryEntry
    let editorName: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 8)
            Text(kindLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            if selected {
                Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(selected ? 0.12 : 0)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open \(entry.name), \(kindLabel)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var kindLabel: String {
        switch entry.kind {
        case .app: return "App"
        case .project: return "Project in \(editorName)"
        case .launcher: return "Launcher"
        }
    }

    @ViewBuilder private var icon: some View {
        if entry.kind == .launcher {
            Image(systemName: "terminal").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable().interpolation(.high).accessibilityHidden(true)
        }
    }
}

/// A transparent area that drags the window when you press and move on it.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// One attached file: a small picture, or a document icon with its name.
/// With `onRemove` it has a button to take it off again.
private struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if attachment.kind == .image, let data = attachment.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: onRemove == nil ? 120 : 40, height: onRemove == nil ? 90 : 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            if attachment.kind == .text || onRemove != nil {
                Text(attachment.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove")
                .accessibilityLabel("Remove \(attachment.name)")
            }
        }
        .padding(onRemove == nil && attachment.kind == .image ? 0 : 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(onRemove == nil && attachment.kind == .image ? 0 : 0.08))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Attached \(attachment.kind == .image ? "image" : "document"): \(attachment.name)")
    }
}


// MARK: - Look

private struct ChatAccentKey: EnvironmentKey { static let defaultValue = Color.accentColor }
private struct ChatOnAccentKey: EnvironmentKey { static let defaultValue = Color.white }
private struct ChatEmbeddedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The colour that marks what can be acted on: the system's in the small window, gold in the dashboard.
    var chatAccent: Color {
        get { self[ChatAccentKey.self] }
        set { self[ChatAccentKey.self] = newValue }
    }
    /// The colour of words set on the accent colour.
    var chatOnAccent: Color {
        get { self[ChatOnAccentKey.self] }
        set { self[ChatOnAccentKey.self] = newValue }
    }
    var chatEmbedded: Bool {
        get { self[ChatEmbeddedKey.self] }
        set { self[ChatEmbeddedKey.self] = newValue }
    }
}

/// The button that carries out a preview. Filled, so it is the one thing on the card that stands out.
private struct ConfirmStyle: ButtonStyle {
    @Environment(\.chatAccent) private var accent
    @Environment(\.chatOnAccent) private var onAccent
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(onAccent)
            .padding(.horizontal, 11).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(accent))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
    }
}

/// A small labelled marker in the dashboard chat's header.
private struct HeaderChip: View {
    let symbol: String
    let text: String
    let colour: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 9).frame(height: 24)
        .overlay(Capsule().strokeBorder(colour.opacity(0.35)))
        .contentShape(Capsule())
    }
}

/// Copies an answer. It shows a tick for a moment so you know it worked.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help(copied ? "Copied" : "Copy this answer")
        .accessibilityLabel(copied ? "Copied" : "Copy this answer")
    }
}

/// The OMNIS mark: a gold ring with a bright point on it, drawn still so it costs nothing to show.
private struct HaloMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().fill(RadialGradient(colors: [Ink.gold.opacity(0.22), .clear], center: .center,
                                             startRadius: side * 0.1, endRadius: side * 0.62))
                    .frame(width: side * 1.3, height: side * 1.3)
                Circle().strokeBorder(AngularGradient(colors: [Ink.goldDeep.opacity(0.35), Ink.gold, Ink.goldLight, Ink.gold, Ink.goldDeep.opacity(0.35)],
                                                      center: .center, angle: .degrees(-120)), lineWidth: side * 0.085)
                    .frame(width: side * 0.78, height: side * 0.78)
                Circle().fill(Ink.goldLight).frame(width: side * 0.14, height: side * 0.14)
                    .shadow(color: Ink.gold.opacity(0.9), radius: side * 0.1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// A place to start in an empty chat.
private struct Starter: Identifiable {
    let symbol: String
    let title: String
    let detail: String
    let prompt: String
    var id: String { title }

    static let all = [
        Starter(symbol: "calendar", title: "What\u{2019}s on today?", detail: "Your calendar and what is due",
                prompt: "What is on my calendar today, and which reminders are due?"),
        Starter(symbol: "envelope", title: "Catch me up on email", detail: "The newest in your inbox",
                prompt: "What are the newest emails in my inbox?"),
        Starter(symbol: "music.note", title: "Play my Liked Songs", detail: "On Spotify",
                prompt: "Play my liked songs on Spotify"),
        Starter(symbol: "sparkles", title: "What can you do?", detail: "A short tour of OMNIS",
                prompt: "What can you do?"),
    ]
}

private struct StarterCard: View {
    let starter: Starter
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: starter.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.gold)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Ink.gold.opacity(0.10)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(starter.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text)
                    Text(starter.detail).font(.system(size: 11)).foregroundStyle(Ink.faint)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.faint).opacity(hovering ? 1 : 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(hovering ? 0.06 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(hovering ? Ink.gold.opacity(0.35) : Ink.line))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .accessibilityLabel("\(starter.title). \(starter.detail)")
    }
}
