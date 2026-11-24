import AppKit
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
                VStack(alignment: .leading, spacing: 0) {
                    // The band beside the notch: the name on one side, where the answers come from on the other.
                    HStack {
                        HStack(spacing: 7) {
                            Circle().strokeBorder(Ink.gold, lineWidth: 1.5).frame(width: 11, height: 11)
                                .overlay(Circle().fill(Ink.goldLight).frame(width: 3.5, height: 3.5))
                            Text("OMNIS").font(.system(size: 11, weight: .semibold)).tracking(3.2)
                        }
                        .accessibilityHidden(true)
                        Spacer(minLength: notchWidth + 24)
                        Text(chat.usesLocal ? "This Mac" : "Claude \u{00B7} \(chat.modelChoice.title)").font(.mono(10)).foregroundStyle(Ink.muted)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: notchHeight)
                    if model.showing == .voice { conversation.padding(.top, 10) } else { everyday.padding(.top, 10) }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(shape.fill(Color.black).shadow(color: .black.opacity(0.55), radius: 18, y: 10))
                .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.0), Color.white.opacity(0.12)], startPoint: .top, endPoint: .bottom)))
                .foregroundStyle(Ink.text)
                .transition(.scale(scale: 0.86, anchor: .top).combined(with: .opacity))
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
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.showing)
        .onExitCommand { model.close() }
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: 30, bottomTrailingRadius: 30, style: .continuous)
    }

    // MARK: A spoken conversation

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                CoreView(level: 0.07 + voice.level * 0.4, running: model.showing == .voice)
                    .animation(.easeOut(duration: 0.12), value: voice.level)
                    .frame(width: 104, height: 104)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(heading).font(.mono(11)).tracking(1.4).foregroundStyle(Ink.gold)
                    Text(voice.inConversation ? voice.stateLine : "Finished").font(.system(size: 17, weight: .medium)).lineLimit(3)
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
        .padding(14)
        .background(cardBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(heading.capitalized): \(title)")
    }

    // MARK: Everyday

    private var everyday: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                musicCard.frame(width: 262)
                calendarCard
                voiceCard.frame(width: 138)
            }
            .frame(height: 136)
            HStack(spacing: 10) {
                askField.frame(width: 262)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.dashboard.tiles.prefix(8)) { entry in
                            Button { model.launch(entry) } label: {
                                HStack(spacing: 6) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable().frame(width: 18, height: 18)
                                    Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                }
                            }
                            .buttonStyle(NotchChip())
                            .accessibilityLabel("Open \(entry.name)")
                        }
                    }
                }
            }
            .frame(height: 36)
        }
    }

    private func cardBackground() -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [Color.white.opacity(0.085), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
    }

    // Music: the cover, the song, and the three controls.
    private var musicCard: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Ink.gold.opacity(0.55), Ink.goldDeep.opacity(0.25), Color.white.opacity(0.05)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                if let artwork = model.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: 30, weight: .medium)).foregroundStyle(Color.white.opacity(0.75))
                }
            }
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let track = model.track {
                    Text(track.title).font(.system(size: 15, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(track.artist).font(.system(size: 12)).foregroundStyle(Ink.muted).lineLimit(1)
                    Spacer(minLength: 2)
                    HStack(spacing: 4) {
                        control("backward.fill", "previous", "Previous track")
                        control(track.playing ? "pause.fill" : "play.fill", "toggle", track.playing ? "Pause" : "Play", large: true)
                        control("forward.fill", "next", "Next track")
                    }
                } else if model.offersMusic {
                    Text("Spotify").font(.system(size: 15, weight: .semibold))
                    Text("See the song and control it from here.").font(.system(size: 12)).foregroundStyle(Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 2)
                    Button("Show music") { model.showMusic() }.buttonStyle(NotchButton(prominent: true)).fixedSize()
                        .help("macOS may ask once whether OMNIS may control Spotify.")
                } else {
                    Text(model.musicNote ?? "No music").font(.system(size: 15, weight: .semibold))
                    Text(model.musicNote == nil ? "Open Spotify to see what\u{2019}s playing here." : "Spotify is open.")
                        .font(.system(size: 12)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 104, alignment: .topLeading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground())
    }

    private func control(_ symbol: String, _ action: String, _ label: String, large: Bool = false) -> some View {
        Button { model.music(action) } label: {
            Image(systemName: symbol).font(.system(size: large ? 15 : 12, weight: .semibold))
                .frame(width: large ? 34 : 30, height: large ? 34 : 30)
        }
        .buttonStyle(NotchRound(filled: large))
        .accessibilityLabel(label)
    }

    // The week, with today picked out, and what is next.
    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 12) {
                Text(NotchData.month(of: model.dashboard.now)).font(.system(size: 24, weight: .bold, design: .rounded))
                    .frame(width: 52, alignment: .leading)
                HStack(spacing: 0) {
                    ForEach(NotchData.week(around: model.dashboard.now)) { day in
                        VStack(spacing: 3) {
                            Text(day.letter).font(.system(size: 9, weight: .semibold)).foregroundStyle(day.isToday ? Ink.gold : Ink.faint)
                            Text("\(day.number)").font(.system(size: 14, weight: day.isToday ? .bold : .medium, design: .rounded))
                                .foregroundStyle(day.isToday ? Ink.ground : Ink.text.opacity(0.82))
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(day.isToday ? Ink.gold : .clear))
                            Circle().fill(model.dashboard.busyDays.contains(day.date) ? (day.isToday ? Ink.gold : Ink.data) : .clear)
                                .frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(day.number)\(day.isToday ? ", today" : "")\(model.dashboard.busyDays.contains(day.date) ? ", has events" : "")")
                    }
                }
            }
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Ink.gold).frame(width: 3, height: 30)
                if let next = NotchData.nextEventParts(in: model.dashboard.agenda, now: model.dashboard.now) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(next.when).font(.system(size: 11)).foregroundStyle(Ink.muted).lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.dashboard.calendarAllowed ? "Nothing more today" : "Calendar not allowed yet").font(.system(size: 13, weight: .semibold))
                        Text(!model.dashboard.calendarAllowed ? "Allow it from the dashboard." : model.reminders.isEmpty ? "Enjoy the gap." : "")
                            .font(.system(size: 11)).foregroundStyle(Ink.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if !model.reminders.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checklist").font(.system(size: 10)).foregroundStyle(Ink.faint)
                    Text(model.reminders.joined(separator: " \u{00B7} ")).font(.system(size: 11)).foregroundStyle(Ink.muted).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Due today: \(model.reminders.joined(separator: ", "))")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground())
    }

    // OMNIS itself: the dots, the voice switch, and how much of Claude is used.
    private var voiceCard: some View {
        VStack(spacing: 5) {
            CoreView(level: voice.isOn ? 0.09 : 0.04, running: model.showing == .everyday)
                .frame(width: 54, height: 54)
                .opacity(voice.isOn ? 1 : 0.6)
                .accessibilityHidden(true)
            Toggle(isOn: Binding(get: { voice.isOn }, set: { voice.isOn = $0 })) {
                Text(voice.isOn ? "Voice on" : "Voice off").font(.system(size: 11, weight: .medium)).foregroundStyle(voice.isOn ? Ink.gold : Ink.muted)
            }
            .toggleStyle(.switch).controlSize(.mini).tint(Ink.gold)
            VStack(spacing: 4) {
                meter("5h", chat.usage.current().fiveHour)
                meter("7d", chat.usage.current().sevenDay)
            }
            .opacity(chat.usesLocal ? 0.35 : 1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground())
    }

    private func meter(_ label: String, _ used: Double?) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.mono(9)).foregroundStyle(Ink.faint).frame(width: 16, alignment: .leading)
            GeometryReader { space in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill((used ?? 0) > 0.65 ? Color.orange : Ink.gold).frame(width: max(3, space.size.width * min(1, used ?? 0)))
                }
            }
            .frame(height: 4)
            Text(used.map { "\(Int(($0 * 100).rounded()))%" } ?? "\u{2013}").font(.mono(9)).foregroundStyle(Ink.muted).frame(width: 26, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude, \(label == "5h" ? "five hours" : "seven days"): \(used.map { "\(Int(($0 * 100).rounded())) percent used" } ?? "not known")")
    }

    private var askField: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 12)).foregroundStyle(Ink.gold)
            TextField("Ask OMNIS", text: $model.ask)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($askFocused)
                .onSubmit { model.submitAsk() }
                .onChange(of: askFocused) { model.typing = askFocused || !model.ask.isEmpty }
                .onChange(of: model.ask) { model.typing = askFocused || !model.ask.isEmpty }
                .accessibilityLabel("Ask OMNIS")
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(askFocused ? Ink.gold.opacity(0.6) : Color.white.opacity(0.08)))
    }
}

/// A launch tile in the notch panel: an icon and a name.
struct NotchChip: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Ink.text)
            .padding(.leading, 9).padding(.trailing, 12)
            .frame(height: 36)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.07)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)))
            .contentShape(Capsule())
    }
}

/// A round control, such as play and pause.
struct NotchRound: ButtonStyle {
    var filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(filled ? Ink.ground : Ink.text)
            .background(Circle().fill(filled ? Ink.gold : Color.white.opacity(configuration.isPressed ? 0.18 : 0.0)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Circle())
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
