import OmnisCore
import SwiftUI

/// The panel that drops from the notch: a spoken conversation while there is
/// one, and a few everyday things when the pointer rests on the notch.
struct NotchView: View {
    @ObservedObject var model: NotchModel
    /// The notch's own height: the panel's content starts below it.
    let notchHeight: CGFloat
    let notchWidth: CGFloat
    @FocusState private var askFocused: Bool

    private var voice: VoiceModel { model.voice }
    private var chat: ChatModel { model.chat }

    var body: some View {
        ZStack(alignment: .top) {
            if model.isOpen {
                VStack(alignment: .leading, spacing: 12) {
                    Color.clear.frame(height: notchHeight)
                    if model.showing == .voice { conversation } else { everyday }
                }
                .padding(.horizontal, 18).padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(shape.fill(Color.black))
                .overlay(shape.strokeBorder(Color.white.opacity(0.07)))
                .foregroundStyle(Ink.text)
                .transition(.opacity)
            } else {
                // Behind the notch itself, something all but invisible for the pointer to land on.
                // The margins either side stay truly clear, so menu-bar items there still take clicks.
                Rectangle().fill(Color.black.opacity(0.02)).frame(width: notchWidth, height: notchHeight)
                if voice.isOn {
                    // A small light beside the notch: voice is on.
                    HStack {
                        Spacer()
                        Circle().fill(Ink.gold).frame(width: 5, height: 5)
                            .shadow(color: Ink.gold.opacity(0.9), radius: 3)
                            .padding(.trailing, 4)
                            .accessibilityLabel("OMNIS voice is on")
                    }
                    .frame(height: notchHeight)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The panel sits under the notch on purpose; macOS must not push its contents down a second time.
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.18), value: model.showing)
        .onExitCommand { model.close() }
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)
    }

    // MARK: A spoken conversation

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                CoreView(level: 0.07 + voice.level * 0.4, running: model.showing == .voice)
                    .animation(.easeOut(duration: 0.12), value: voice.level)
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(heading).font(.mono(11)).tracking(1.4).foregroundStyle(Ink.gold)
                    Text(voice.inConversation ? voice.stateLine : "Finished").font(.system(size: 14)).lineLimit(3)
                        .truncationMode(.head).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                if voice.state == .speaking {
                    Button("Stop") { voice.interrupt() }.buttonStyle(NotchButton(prominent: false))
                        .help("Stop reading this aloud")
                } else if !voice.inConversation {
                    // The conversation is over and something is still waiting: it can be put away for later.
                    Button("Hide") { model.close() }.buttonStyle(NotchButton(prominent: false))
                        .help("Hide this. It stays in the chat window.")
                }
            }
            if let answer = model.waitingAnswer {
                // However long a preview is, all of it can be reached before anything is clicked.
                ScrollView { VStack(alignment: .leading, spacing: 10) { waiting(answer) } }
            }
        }
    }

    private var heading: String {
        switch voice.state {
        case .speaking: return "OMNIS"
        case .thinking: return "THINKING"
        case .confirming: return "YES OR NO?"
        case .listening, .followUp: return "LISTENING"
        case .waiting, .off: return "VOICE"
        }
    }

    /// Whatever the latest answer left for the user to decide, with the same buttons as in the chat.
    @ViewBuilder private func waiting(_ answer: ChatMessage) -> some View {
        if answer.searchAsk?.state == .waiting {
            card(heading: "WEB SEARCH", title: "Allow web searches in this chat?",
                 lines: [answer.searchAsk?.query ?? ""].filter { !$0.isEmpty },
                 decline: ("Don\u{2019}t Search", { chat.answerSearchAsk(false) }), confirm: ("Allow", { chat.answerSearchAsk(true) }))
        }
        ForEach(answer.actions.filter { $0.state == .waiting }.prefix(2)) { action in
            card(heading: action.heading.uppercased(), title: action.title, lines: action.rows.map { "\($0.label): \($0.value)" },
                 decline: (action.declineLabel, { chat.declineAction(action.id) }), confirm: (action.confirmLabel, { chat.confirmAction(action.id) }),
                 destructive: action.destructive)
        }
        ForEach(answer.proposals.filter { $0.state == .waiting }.prefix(2)) { proposal in
            card(heading: proposal.change.heading.uppercased(), title: proposal.change.line(), lines: [],
                 decline: ("Don\u{2019}t", { chat.decline(proposal.id) }), confirm: ("Confirm", { chat.confirm(proposal.id) }))
        }
        if answer.projects.contains(where: { $0.state == .waiting }) {
            Text("A new project is ready to check in the chat window.").font(.system(size: 12)).foregroundStyle(Ink.muted)
        }
    }

    private func card(heading: String, title: String, lines: [String], decline: (String, () -> Void), confirm: (String, () -> Void),
                      destructive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.mono(10)).tracking(1.2).foregroundStyle(destructive ? Color.red : Ink.muted)
            Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            // Everything is shown, however long: a click here does what a click in the chat does.
            ForEach(lines, id: \.self) { line in
                Text(line).font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(decline.0, action: decline.1).buttonStyle(NotchButton(prominent: false))
                Button(confirm.0, action: confirm.1).buttonStyle(NotchButton(prominent: true, destructive: destructive))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(heading.capitalized): \(title)")
    }

    // MARK: Everyday

    private var everyday: some View {
        VStack(alignment: .leading, spacing: 11) {
            line("NEXT", model.nextEvent ?? (model.dashboard.calendarAllowed ? "Nothing more today" : "Calendar not allowed yet"))
            if !model.reminders.isEmpty { line("DUE", model.reminders.joined(separator: " \u{00B7} ")) }
            music
            HStack(spacing: 10) {
                Text(chat.usesLocal ? "This Mac" : (chat.usageLabel ?? "Claude")).font(.mono(11))
                    .foregroundStyle(chat.usageIsHigh ? Color.orange : Ink.muted)
                Spacer(minLength: 8)
                Toggle(isOn: Binding(get: { voice.isOn }, set: { voice.isOn = $0 })) {
                    Text("Voice").font(.mono(11)).foregroundStyle(Ink.muted)
                }
                .toggleStyle(.switch).controlSize(.mini)
            }
            TextField("Ask OMNIS", text: $model.ask)
                .textFieldStyle(.plain).font(.system(size: 14))
                .focused($askFocused)
                .onSubmit { model.submitAsk() }
                .onChange(of: askFocused) { model.typing = askFocused || !model.ask.isEmpty }
                .onChange(of: model.ask) { model.typing = askFocused || !model.ask.isEmpty }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .accessibilityLabel("Ask OMNIS")
            if !model.dashboard.tiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.dashboard.tiles.prefix(6)) { entry in
                            Button(entry.name) { model.launch(entry) }.buttonStyle(NotchButton(prominent: false))
                                .accessibilityLabel("Open \(entry.name)")
                        }
                    }
                }
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.mono(10)).tracking(1.2).foregroundStyle(Ink.faint).frame(width: 38, alignment: .leading)
            Text(value).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var music: some View {
        if let track = model.track {
            HStack(spacing: 10) {
                Image(systemName: "music.note").font(.system(size: 11)).foregroundStyle(Ink.faint).frame(width: 38, alignment: .leading)
                Text(track.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                ForEach([("backward.fill", "previous", "Previous track"), (track.playing ? "pause.fill" : "play.fill", "toggle", track.playing ? "Pause" : "Play"),
                         ("forward.fill", "next", "Next track")], id: \.1) { symbol, action, label in
                    Button { model.music(action) } label: { Image(systemName: symbol).font(.system(size: 12)).frame(width: 24, height: 22) }
                        .buttonStyle(.plain).foregroundStyle(Ink.text).contentShape(Rectangle()).accessibilityLabel(label)
                }
            }
        } else if let note = model.musicNote {
            line("MUSIC", note)
        }
    }
}

/// The small rounded buttons used in the notch panel.
struct NotchButton: ButtonStyle {
    var prominent: Bool
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? (destructive ? Color.white : Ink.ground) : Ink.text)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(prominent ? (destructive ? Color.red : Ink.gold) : Color.white.opacity(0.09)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
