import OmnisCore
import SwiftUI

/// The list of saved chats beside the conversation in the dashboard: start a
/// new one, find an old one, and open, rename, pin or delete it.
struct ChatSidebar: View {
    @ObservedObject var model: ChatModel
    /// True in the small window's popover, where there is no room for the footer.
    var compact = false
    /// Called after a chat is opened, so a popover can close.
    var onOpen: () -> Void = {}

    @State private var renaming: UUID?
    @State private var draftTitle = ""
    @State private var deleting: ChatSummary?
    @State private var confirmDeleteAll = false
    @State private var showMemory = false
    /// A shorter time to keep chats, waiting for the user to agree to what it removes.
    @State private var shorter: Int?
    @FocusState private var renameFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !compact { newChatButton }
            searchField
            list
            if !compact { footer }
        }
        .padding(compact ? 12 : 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(compact ? Color.clear : Ink.panel))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(compact ? Color.clear : Ink.line))
        .foregroundStyle(Ink.text)
        .confirmationDialog("Delete \u{201C}\(deleting?.title ?? "")\u{201D}?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Chat", role: .destructive) {
                if let deleting { model.deleteChat(deleting.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("It is removed from this Mac and cannot be brought back.")
        }
        .onAppear { model.refreshChats() }
    }

    private var newChatButton: some View {
        Button(action: model.newChat) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text("New chat").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\u{2318}N").font(.mono(10)).opacity(0.6)
            }
            .foregroundStyle(Ink.ground)
            .padding(.horizontal, 12).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.gold))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut("n", modifiers: .command)
        .disabled(model.conversation.isEmpty)
        .opacity(model.conversation.isEmpty ? 0.45 : 1)
        .help("Start a new chat. This one stays in the list.")
        .accessibilityLabel("New chat")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.faint)
            TextField("Search chats", text: $model.chatSearch)
                .textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
                .accessibilityLabel("Search saved chats")
            if !model.chatSearch.isEmpty {
                Button { model.chatSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Ink.faint)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(searchFocused ? Ink.gold.opacity(0.45) : Color.clear))
    }

    // MARK: The list

    @ViewBuilder private var list: some View {
        if model.chats.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: model.chatSearch.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                    .font(.system(size: 20)).foregroundStyle(Ink.faint.opacity(0.7))
                Text(model.chatSearch.isEmpty ? "Your chats will be listed here." : "No chat has those words.")
                    .font(.system(size: 12)).foregroundStyle(Ink.faint).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(ChatAge.grouped(model.chats), id: \.age) { group in
                        Text(group.age.rawValue.uppercased())
                            .font(.mono(10)).tracking(1.4).foregroundStyle(Ink.faint)
                            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.chats) { chat in row(chat) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private func row(_ chat: ChatSummary) -> some View {
        if renaming == chat.id {
            TextField("Name", text: $draftTitle)
                .textFieldStyle(.plain).font(.system(size: 13, weight: .medium)).focused($renameFocused)
                .padding(.horizontal, 10).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Ink.gold.opacity(0.5)))
                .onSubmit { finishRename(chat.id) }
                .onExitCommand { renaming = nil }
                .onChange(of: renameFocused) { if !renameFocused, renaming == chat.id { finishRename(chat.id) } }
                .accessibilityLabel("New name for this chat")
        } else {
            ChatRow(chat: chat, selected: chat.id == model.chatID,
                    open: { model.openChat(chat.id); onOpen() },
                    rename: { beginRename(chat) },
                    pin: { model.setPinned(chat.id, !chat.pinned) },
                    delete: { deleting = chat })
        }
    }

    private func beginRename(_ chat: ChatSummary) {
        draftTitle = chat.title
        renaming = chat.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func finishRename(_ id: UUID) {
        model.renameChat(id, to: draftTitle)
        renaming = nil
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Ink.line).frame(height: 1)
            Button { showMemory.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundStyle(Ink.gold)
                    Text("Memory").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(model.memoryFacts.isEmpty ? "Nothing yet" : "\(model.memoryFacts.count)")
                        .font(.mono(11)).foregroundStyle(Ink.faint)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.faint)
                }
                .padding(.horizontal, 8).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(showMemory ? 0.08 : 0.001)))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .help("What OMNIS remembers about you between chats")
            .accessibilityLabel("Memory: \(model.memoryFacts.count) things remembered")
            .popover(isPresented: $showMemory, arrowEdge: .trailing) { MemoryPanel(model: model) }

            Menu {
                Picker("Keep chats for", selection: Binding(get: { model.retentionDays }, set: { days in
                    // A shorter time removes older chats at once, so it is agreed to first.
                    if model.chatsRemoved(byKeeping: days) > 0 { shorter = days } else { model.retentionDays = days }
                })) {
                    ForEach(ChatModel.retentionChoices, id: \.days) { choice in Text(choice.title).tag(choice.days) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Delete All Chats\u{2026}", role: .destructive) { confirmDeleteAll = true }.disabled(model.chats.isEmpty)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive").font(.system(size: 10))
                    Text(retentionLine).font(.system(size: 11)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Ink.faint)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Chats are saved on this Mac only. Pinned chats are kept until you delete them.")
            .accessibilityLabel("How long chats are kept: \(retentionLine)")
        }
        .confirmationDialog("Delete every saved chat?", isPresented: $confirmDeleteAll) {
            Button("Delete All Chats", role: .destructive) { model.deleteAllChats() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(model.chats.count) are removed from this Mac, pinned ones too, and cannot be brought back. What OMNIS remembers is kept.")
        }
        .alert("Remove older chats?", isPresented: Binding(get: { shorter != nil }, set: { if !$0 { shorter = nil } })) {
            Button("Remove Them", role: .destructive) {
                if let shorter { model.retentionDays = shorter }
                shorter = nil
            }
            Button("Cancel", role: .cancel) { shorter = nil }
        } message: {
            let count = shorter.map(model.chatsRemoved(byKeeping:)) ?? 0
            Text("\(count == 1 ? "1 chat has" : "\(count) chats have") not been used for \(shorter ?? 0) days and will be removed now. Pinned chats and the one that is open are kept.")
        }
    }

    private var retentionLine: String {
        switch model.retentionDays {
        case 0: return "On this Mac, until deleted"
        default: return "On this Mac for \(model.retentionDays) days"
        }
    }
}

/// One saved chat in the list.
private struct ChatRow: View {
    let chat: ChatSummary
    let selected: Bool
    let open: () -> Void
    let rename: () -> Void
    let pin: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            // The marker for the chat that is open.
            Capsule().fill(selected ? Ink.gold : .clear).frame(width: 2.5, height: 22).padding(.trailing, 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).font(.system(size: 13, weight: selected ? .semibold : .medium)).lineLimit(1)
                    .foregroundStyle(selected ? Ink.text : Ink.text.opacity(0.9))
                HStack(spacing: 5) {
                    if chat.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Ink.gold) }
                    Text(ChatRow.when(chat.updated)).font(.mono(10)).foregroundStyle(Ink.faint).layoutPriority(1)
                    if !chat.preview.isEmpty {
                        Text(chat.preview).font(.system(size: 11)).foregroundStyle(Ink.faint).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if hovering {
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.muted)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More for \(chat.title)")
            }
        }
        .padding(.leading, 3).padding(.trailing, 5).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(selected ? 0.075 : hovering ? 0.04 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu { actions }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chat.title), \(ChatRow.when(chat.updated))\(chat.pinned ? ", pinned" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Open", open)
        .accessibilityAction(named: "Rename", rename)
        .accessibilityAction(named: chat.pinned ? "Unpin" : "Pin", pin)
        .accessibilityAction(named: "Delete", delete)
    }

    @ViewBuilder private var actions: some View {
        Button("Rename", action: rename)
        Button(chat.pinned ? "Unpin" : "Pin, so it is kept", action: pin)
        Divider()
        Button("Delete\u{2026}", role: .destructive, action: delete)
    }

    /// "14:05" today, "Tue" this week, "3 Nov" before that.
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= week {
            formatter.dateFormat = "EEE"
        } else {
            formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "d MMM" : "d MMM yy"
        }
        return formatter.string(from: date)
    }
}

/// A button that dips a little when pressed, and nothing else.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// What OMNIS remembers: see it, add to it, change it, remove from it.
struct MemoryPanel: View {
    @ObservedObject var model: ChatModel
    @State private var draft = ""
    @State private var editing: UUID?
    @State private var editText = ""
    @State private var confirmClear = false
    @FocusState private var editFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MEMORY").font(.mono(11)).tracking(1.5).foregroundStyle(Ink.muted)
                Text("OMNIS keeps these in mind in every chat. Nothing is added unless you put it here or approve it. The list is kept on this Mac and is passed to Claude with your questions.")
                    .font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            }
            if model.memoryFacts.isEmpty {
                Text("Nothing is remembered yet. Add something below, or say \u{201C}remember that\u{2026}\u{201D} in a chat.")
                    .font(.system(size: 12)).foregroundStyle(Ink.faint).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 10)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.memoryFacts) { fact in factRow(fact) }
                    }
                }
                .frame(maxHeight: 300)
            }
            HStack(spacing: 8) {
                TextField("Something to remember, such as \u{201C}I prefer metric units\u{201D}", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                    .onSubmit(add)
                    .accessibilityLabel("Something to remember")
                Button("Add", action: add)
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.ground)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Ink.gold))
                    .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("\(model.memoryFacts.count) of \(MemoryStore.maxFacts)").font(.mono(10)).foregroundStyle(Ink.faint)
                Spacer()
                if !model.memoryFacts.isEmpty {
                    Button("Forget everything\u{2026}") { confirmClear = true }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Ink.faint)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(Ink.lift)
        .foregroundStyle(Ink.text)
        .preferredColorScheme(.dark)
        .confirmationDialog("Forget everything OMNIS remembers?", isPresented: $confirmClear) {
            Button("Forget Everything", role: .destructive) { model.forgetEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(model.memoryFacts.count) are removed and cannot be brought back. Your saved chats are kept.")
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if model.remember(text) { draft = "" }
    }

    @ViewBuilder private func factRow(_ fact: MemoryFact) -> some View {
        if editing == fact.id {
            TextField("", text: $editText, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4).focused($editFocused)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Ink.gold.opacity(0.5)))
                .onSubmit {
                    model.updateMemory(fact.id, to: editText)
                    editing = nil
                }
                .onExitCommand { editing = nil }
                // Clicking away keeps the change, as pressing Return does.
                .onChange(of: editFocused) {
                    if !editFocused, editing == fact.id {
                        model.updateMemory(fact.id, to: editText)
                        editing = nil
                    }
                }
                .accessibilityLabel("Change what is remembered")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Ink.gold.opacity(0.8)).frame(width: 4, height: 4).offset(y: -3)
                Text(fact.text).font(.system(size: 13)).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                Button {
                    editText = fact.text
                    editing = fact.id
                    DispatchQueue.main.async { editFocused = true }
                } label: { Image(systemName: "pencil").font(.system(size: 11)) }
                    .help("Change").accessibilityLabel("Change: \(fact.text)")
                Button { model.forget(fact.id) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .help("Forget this").accessibilityLabel("Forget: \(fact.text)")
            }
            .buttonStyle(.plain).foregroundStyle(Ink.muted)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.03)))
        }
    }
}
