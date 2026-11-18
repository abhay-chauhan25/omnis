import AppKit
import OmnisCore
import SwiftUI

/// The chat window: a header you can drag, the conversation, and the input bar.
struct ChatView: View {
    @ObservedObject var model: ChatModel
    let onClose: () -> Void
    @FocusState private var inputFocused: Bool
    @State private var dropTargeted = false

    static let corner: CGFloat = 26
    private static let bottomID = "bottom"

    var body: some View {
        VStack(spacing: 0) {
            header
            conversation
            inputBar
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .ignoresSafeArea()
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
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

    private func focusInput() {
        DispatchQueue.main.async { inputFocused = true }
    }

    // MARK: Header

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
                Spacer()
                if model.conversation.staysLocal {
                    Label("On this Mac", systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .medium))
                        .help("This chat is staying on this Mac, because you kept it local or it holds a file or your calendar. Start a new chat to use Claude.")
                        .accessibilityLabel("This chat is staying on this Mac")
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

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.conversation.isEmpty {
                        emptyState
                    }
                    ForEach(model.conversation.messages) { message in
                        MessageView(message: message, open: model.open, confirm: model.confirm, decline: model.decline)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.conversation) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
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
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.10))
            )
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
                .foregroundStyle(model.webEnabled ? Color.accentColor : Color.secondary)
                .help(model.webEnabled ? "OMNIS may search the web when a question needs it. Click to turn off."
                                       : "Web search is off. Click to turn on.")
                .accessibilityLabel(model.webEnabled ? "Web search on" : "Web search off")
            }

            Menu {
                Picker("Answer with", selection: $model.lane) {
                    ForEach(ChatModel.Lane.allCases) { lane in
                        Text(lane.title).tag(lane)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(model.lane.title)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Auto lets OMNIS choose. Local keeps the question on this Mac. Claude sends it to Claude.")
            .accessibilityLabel("Answer with \(model.lane.title)")

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
                .foregroundStyle(model.canSend ? Color.accentColor : Color.secondary.opacity(0.5))
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

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        AttachmentChip(attachment: attachment, onRemove: nil)
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accentColor))
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
            Text("Stopped").font(.system(size: 11)).foregroundStyle(.tertiary)
        case .done:
            if let line = message.sourceLine {
                Text(line).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
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

/// A new event, shown for the user to check. Nothing is on the calendar
/// until "Add to Calendar" is clicked.
private struct EventCard: View {
    let proposal: EventProposal
    let confirm: () -> Void
    let decline: () -> Void

    private var isLive: Bool { proposal.state == .waiting || proposal.state == .saving }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 18))
                    .foregroundStyle(isLive ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.draft.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    Text(proposal.draft.when())
                        .font(.system(size: 13))
                    if let place = proposal.draft.location {
                        Label(place, systemImage: "mappin.and.ellipse")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if isLive {
                        Text("Calendar: \(proposal.calendarName ?? "your default calendar")")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if proposal.draft.start < Date() {
                            Label("This time is in the past", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            footer
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New event: \(proposal.draft.title), \(proposal.draft.when())")
    }

    @ViewBuilder private var footer: some View {
        switch proposal.state {
        case .waiting:
            HStack(spacing: 8) {
                Text("Not added yet").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("Don't Add", action: decline)
                Button("Add to Calendar", action: confirm)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        case .saving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Adding").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .added(let calendar):
            Label("Added to \(calendar)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(.green)
        case .declined:
            Text("Not added").font(.system(size: 12)).foregroundStyle(.secondary)
        case .replaced:
            Text("Not added. Replaced by a newer preview below.").font(.system(size: 12)).foregroundStyle(.secondary)
        case .failed(let why):
            Label("Could not add it: \(why)", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(.secondary)
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
