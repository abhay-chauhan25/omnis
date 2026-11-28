import OmnisCore
import SwiftUI

/// The colours of the dashboard. Dark whatever the system setting, by design.
enum Ink {
    static let ground = Color(red: 0.024, green: 0.031, blue: 0.043)
    static let lift = Color(red: 0.055, green: 0.075, blue: 0.102)
    static let text = Color(red: 0.91, green: 0.93, blue: 0.95)
    static let muted = Color(red: 0.60, green: 0.65, blue: 0.71)
    static let faint = Color(red: 0.49, green: 0.54, blue: 0.59)
    static let gold = Color(red: 0.949, green: 0.757, blue: 0.306)
    static let goldDeep = Color(red: 0.788, green: 0.592, blue: 0.184)
    static let goldLight = Color(red: 1.0, green: 0.945, blue: 0.761)
    static let data = Color(red: 0.557, green: 0.773, blue: 1.0)
    static let line = Color.white.opacity(0.08)
    static let panel = Color.white.opacity(0.025)
}

extension Font {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

/// A titled box. Every panel on the dashboard is one of these.
private struct Panel<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.mono(11)).tracking(1.5).foregroundStyle(Ink.muted)
                Spacer(minLength: 8)
                trailing()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title.capitalized)
    }
}

private extension Panel where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var chat: ChatModel
    @ObservedObject var project: ProjectModeModel
    @ObservedObject var voice: VoiceModel
    @FocusState private var askFocused: Bool
    @State private var showVoiceSettings = false
    /// Whether the extra usage facts are showing. Hidden until asked for.
    @AppStorage("OMNISShowMoreFacts") private var showMoreFacts = false

    var body: some View {
        // Everything fits the window: the centre is laid out to the height
        // there is, and a side column scrolls only if the window is too short for it.
        VStack(spacing: 18) {
            header
            if model.showChat {
                // Chat mode: the same conversation as the small window, with room to read.
                ChatView(model: chat, onClose: { model.moveChatToSmallWindow() }, embedded: true).frame(maxHeight: .infinity)
            } else if model.showActivity {
                // Activity mode replaces the panels with the record of what OMNIS did.
                ActivityView(model: model).frame(maxHeight: .infinity)
            } else if project.isActive {
                // Project mode replaces the panels with terminals and the advisor.
                ProjectModeView(model: project).frame(maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ScrollView(showsIndicators: false) { VStack(spacing: 18) { today; focusAndCapture; mail } }
                        .frame(minWidth: 280, maxWidth: 360)
                    centre.frame(minWidth: 420, maxWidth: .infinity)
                    ScrollView(showsIndicators: false) { VStack(spacing: 18) { usage; system; activity } }
                        .frame(minWidth: 280, maxWidth: 360)
                }
                .frame(maxHeight: .infinity)
                projects
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 20)
        // Fresh figures as soon as an answer finishes, without waiting for the next refresh.
        .onChange(of: chat.isAnswering) { if !chat.isAnswering { model.refresh() } }
        .background(
            RadialGradient(colors: [Ink.lift, Ink.ground], center: UnitPoint(x: 0.5, y: 0.38), startRadius: 0, endRadius: 760)
                .ignoresSafeArea()
        )
        .foregroundStyle(Ink.text)
        .preferredColorScheme(.dark)
    }

    // MARK: Top

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("OMNIS").font(.system(size: 17, weight: .semibold)).tracking(5.5)
            HStack(spacing: 2) {
                modeButton("Dashboard", on: !project.isActive && !model.showActivity && !model.showChat) {
                    model.showChat = false; model.showActivity = false; project.isActive = false
                }
                modeButton("Chat", on: model.showChat) { model.showActivity = false; model.showChat = true }
                modeButton("Project", on: project.isActive && !model.showActivity && !model.showChat) {
                    model.showChat = false; model.showActivity = false; project.isActive = true
                }
                modeButton("Activity", on: model.showActivity && !model.showChat) { model.showChat = false; project.isActive = false; model.showActivity = true }
            }
            .padding(3)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("View")
            if project.runningCount > 0 {
                Text(project.runningCount == 1 ? "1 session running" : "\(project.runningCount) sessions running")
                    .font(.mono(11)).foregroundStyle(Ink.gold)
            }
            Spacer()
            voiceControl
            chip(chat.usesLocal ? chat.localLabel : "Claude \u{00B7} \(chat.modelChoice.title)", color: Ink.text)
            if let usage = chat.usageLabel { chip(usage, color: chat.usageIsHigh ? .orange : Ink.text) }
            VStack(alignment: .trailing, spacing: 1) {
                Text(model.clock).font(.mono(20, weight: .medium))
                Text(model.dateLine).font(.mono(11)).foregroundStyle(Ink.faint)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The voice switch. Clicking it opens the switch itself and how OMNIS should sound.
    private var voiceControl: some View {
        Button { showVoiceSettings.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: voice.isOn ? "mic.fill" : "mic.slash").font(.system(size: 10))
                Text(voice.isOn ? "Voice on" : "Voice off").font(.mono(11))
            }
            .foregroundStyle(voice.isOn ? Ink.gold : Ink.muted)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(voice.isOn ? Ink.gold.opacity(0.5) : Color.white.opacity(0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(voice.isOn ? "Voice is on. Open voice settings" : "Voice is off. Open voice settings")
        .popover(isPresented: $showVoiceSettings, arrowEdge: .bottom) { VoiceSettingsView(voice: voice) }
    }

    private func modeButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Ink.ground : Ink.muted)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(on ? Ink.gold : .clear))
            .contentShape(Capsule())
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text).font(.mono(11)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
    }

    // MARK: Left

    private var today: some View {
        Panel(title: "TODAY", trailing: {
            if let badge = model.nextBadge { Text(badge).font(.mono(11)).tracking(1).foregroundStyle(Ink.gold) }
        }) {
            if !model.calendarAllowed {
                Text("OMNIS has not been allowed to read your calendar yet.").font(.system(size: 13)).foregroundStyle(Ink.muted)
                Button("Allow calendar access") { model.allowCalendar() }.buttonStyle(PillButton())
            } else if model.agenda.isEmpty {
                Text("Nothing on for the rest of today.").font(.system(size: 14))
            } else {
                VStack(spacing: 2) {
                    ForEach(model.agenda) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.time).font(.mono(12)).foregroundStyle(row.isNext ? Ink.gold : Ink.muted)
                                .frame(width: 54, alignment: .leading)
                            Text(row.title).font(.system(size: 14)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.calendar.uppercased()).font(.mono(10)).foregroundStyle(Ink.faint).lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(row.isNext ? Color.white.opacity(0.06) : .clear))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if model.calendarAllowed, let line = model.tomorrowLine {
                Text(line).font(.system(size: 12)).foregroundStyle(Ink.faint)
            }
        }
    }

    private var focusAndCapture: some View {
        HStack(alignment: .top, spacing: 18) {
            Panel(title: "FOCUS") {
                Text(model.focusDone ? "Done" : model.focusLabel).font(.mono(26, weight: .medium))
                    .foregroundStyle(model.focus.isRunning ? Ink.gold : Ink.text)
                    .accessibilityLabel(model.focusDone ? "Focus time finished" : "Focus time left \(model.focusLabel)")
                Button(model.focus.isRunning ? "Stop" : "Start") { model.toggleFocus() }.buttonStyle(PillButton())
            }
            .frame(width: 122)
            Panel(title: "QUICK CAPTURE") {
                TextField("A thought to keep", text: $model.capture)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1) }
                    .onSubmit { model.saveCapture() }
                    .accessibilityLabel("Quick capture")
                HStack {
                    Text(model.captureNotice ?? (model.notesToday == 1 ? "1 captured today." : "\(model.notesToday) captured today."))
                        .font(.system(size: 12)).foregroundStyle(Ink.faint)
                    Spacer()
                    Button("Open notes") { model.openNotes() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Ink.muted)
                        .disabled(model.notesToday == 0 && !FileManager.default.fileExists(atPath: OmnisPaths.notesFile.path))
                }
            }
        }
    }

    private var mail: some View {
        Panel(title: "MAIL, SUMMARISED", trailing: {
            Text("NOT BUILT YET").font(.mono(10)).foregroundStyle(Ink.muted)
                .padding(.horizontal, 7).padding(.vertical, 2).overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
        }) {
            Text("Once mail is connected, this shows what needs a reply and what can wait. Replies will be drafted for you to approve; nothing is sent without your click.")
                .font(.system(size: 13)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Centre

    private var centre: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text(model.greeting).font(.system(size: 30, weight: .medium))
                Text(model.summary).font(.system(size: 14)).foregroundStyle(Ink.muted).multilineTextAlignment(.center)
            }
            // The core takes the room that is left, up to a comfortable size,
            // so the ask bar and tiles below it are always in view.
            // In a spoken conversation the dots swell with the voice: OMNIS's own
            // while it speaks, yours while it listens.
            CoreView(level: voice.inConversation ? 0.06 + voice.level * 0.34 : chat.isAnswering ? 0.13 : 0.045, running: model.isVisible)
                .animation(voice.inConversation ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.9),
                           value: voice.inConversation ? voice.level : (chat.isAnswering ? 1 : 0))
                .aspectRatio(1, contentMode: .fit)
                .frame(minHeight: 150, maxHeight: 380)
                .accessibilityHidden(true)
            HStack(spacing: 10) {
                Circle().fill(chat.isAnswering || voice.inConversation ? Ink.gold : Ink.faint).frame(width: 7, height: 7)
                if voice.inConversation {
                    Text(voice.stateLine).font(.mono(12)).foregroundStyle(Ink.muted).lineLimit(1).truncationMode(.head)
                    if voice.state == .speaking {
                        Button("Stop") { voice.interrupt() }.buttonStyle(.plain).font(.mono(11)).foregroundStyle(Ink.gold)
                            .keyboardShortcut(.escape, modifiers: [])
                            .help("Stop reading this aloud (Esc)")
                    }
                    Button("End") { voice.endConversation() }.buttonStyle(.plain).font(.mono(11)).foregroundStyle(Ink.muted)
                        .help("End this conversation")
                } else {
                    Text(chat.isAnswering ? "ANSWERING" : voice.isOn ? "READY \u{00B7} SAY \u{201C}HEY OMNIS\u{201D}" : "READY")
                        .font(.mono(12)).tracking(1.5).foregroundStyle(Ink.muted)
                }
            }
            .accessibilityElement(children: .combine)
            askBar
            launchTiles
            Spacer(minLength: 0)
        }
    }

    private var askBar: some View {
        HStack(spacing: 10) {
            TextField("Ask OMNIS", text: $model.ask)
                .textFieldStyle(.plain).font(.system(size: 16))
                .focused($askFocused)
                .onSubmit { model.submit() }
                .accessibilityLabel("Ask OMNIS")
            Button { model.submit() } label: {
                Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(Ink.ground)
                    .frame(width: 34, height: 34).background(Circle().fill(Ink.gold))
            }
            .buttonStyle(.plain)
            .disabled(model.ask.trimmingCharacters(in: .whitespaces).isEmpty || chat.isAnswering)
            .help("Ask. The answer opens in the chat window.")
            .accessibilityLabel("Send")
        }
        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
        .frame(maxWidth: 620)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }

    private var launchTiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LAUNCH").font(.mono(11)).tracking(1.5).foregroundStyle(Ink.muted)
                Spacer()
                Text("ordered by what you open most").font(.mono(11)).foregroundStyle(Ink.faint)
            }
            if model.tiles.isEmpty {
                Text("Open an app or project from the chat window and it will appear here.").font(.system(size: 12)).foregroundStyle(Ink.faint)
            }
            if let notice = chat.notice {
                // What happened when a tile was clicked: "Opened Ghidra", or why it could not be.
                Text(notice).font(.system(size: 12)).foregroundStyle(Ink.muted).lineLimit(2)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(model.tiles) { entry in
                    Button { model.launch(entry) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                            Text(entry.kind.rawValue.uppercased()).font(.mono(10)).foregroundStyle(Ink.faint)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.panel))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.line))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(entry.name)")
                }
            }
        }
        .frame(maxWidth: 620)
    }

    // MARK: Right

    private var usage: some View {
        Panel(title: "CLAUDE USAGE") {
            let live = chat.usage.current()
            meter("Five-hour window", used: live.fiveHour, stop: chat.limits.fiveHour, resets: live.fiveHourResets)
            meter("This week", used: live.sevenDay, stop: chat.limits.sevenDay, resets: live.sevenDayResets)
            if live.fiveHour == nil && live.sevenDay == nil {
                Text("Shown after the first question to Claude.").font(.system(size: 12)).foregroundStyle(Ink.faint)
            }
            Rectangle().fill(Ink.line).frame(height: 1)
            statistics
        }
    }

    /// The user's Claude Code usage over a chosen span: a calendar of busy
    /// days, then totals and a few facts.
    @ViewBuilder private var statistics: some View {
        HStack(spacing: 6) {
            ForEach(StatsRange.allCases) { range in
                Button(range.title) { model.statsRange = range }
                    .buttonStyle(.plain)
                    .font(.mono(11, weight: model.statsRange == range ? .semibold : .regular))
                    .foregroundStyle(model.statsRange == range ? Ink.gold : Ink.muted)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(model.statsRange == range ? Ink.gold.opacity(0.12) : .clear))
                    .accessibilityAddTraits(model.statsRange == range ? .isSelected : [])
            }
        }
        if let summary = model.statsSummary {
            heatmap(summary)
            VStack(alignment: .leading, spacing: 5) {
                fact("Favourite model", summary.favourite ?? "\u{2013}", highlight: true)
                fact("Total tokens", DashboardData.compactLarge(model.statsRange == .all ? (summary.breakdown?.all ?? summary.tokens) : summary.tokens),
                     highlight: true)
                Button {
                    showMoreFacts.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showMoreFacts ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text(showMoreFacts ? "Fewer facts" : "More facts").font(.mono(11))
                    }
                    .foregroundStyle(Ink.muted)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showMoreFacts ? "Hide the extra facts" : "Show more facts")
                if showMoreFacts { moreFacts(summary) }
            }
        } else {
            Text("Claude Code has no usage statistics on this Mac yet.").font(.system(size: 12)).foregroundStyle(Ink.faint)
        }
    }

    @ViewBuilder private func moreFacts(_ summary: ClaudeStats.Summary) -> some View {
                if summary.models.count > 1 {
                    fact("Models", summary.models.map { "\($0.name) \($0.percent)%" }.joined(separator: " \u{00B7} "))
                }
                fact("Sessions", "\(summary.sessions)")
                fact("Messages", DashboardData.compact(summary.messages))
                fact("Active days", "\(summary.activeDays) of \(summary.totalDays)")
                if let busiest = summary.mostActive {
                    fact("Most active day", "\(Self.dayName(busiest.date)) \u{00B7} \(DashboardData.compact(busiest.messages)) messages")
                }
                fact("Longest streak", summary.longestStreak == 1 ? "1 day" : "\(summary.longestStreak) days")
                fact("Current streak", summary.currentStreak == 1 ? "1 day" : "\(summary.currentStreak) days")
                if let longest = summary.longestSession { fact("Longest session", longest) }
                if let hour = summary.busiestHour { fact("Busiest hour", String(format: "%02d:00", hour)) }
                if let parts = summary.breakdown {
                    Text("In \(DashboardData.compactLarge(parts.input)) \u{00B7} out \(DashboardData.compactLarge(parts.output)) \u{00B7} cache read \(DashboardData.compactLarge(parts.cacheRead)) \u{00B7} cache write \(DashboardData.compactLarge(parts.cacheWrite))")
                        .font(.mono(10)).foregroundStyle(Ink.faint).fixedSize(horizontal: false, vertical: true)
                }
                if let novels = summary.novelsWritten {
                    Text("Claude has written you about \(novels) novels' worth of text.")
                        .font(.system(size: 12)).foregroundStyle(Ink.data).fixedSize(horizontal: false, vertical: true)
                }
        Text("Through OMNIS, last 30 days: \(model.history.questions) questions \u{00B7} \(DashboardData.compact(model.history.tokens)) tokens \u{00B7} today \(DashboardData.compact(model.history.tokensToday))")
            .font(.mono(10)).foregroundStyle(Ink.faint).fixedSize(horizontal: false, vertical: true)
    }

    /// Busy days as squares. Seven days are shown in a row with their names;
    /// longer spans as a calendar on its side, a column per week from Monday.
    @ViewBuilder private func heatmap(_ summary: ClaudeStats.Summary) -> some View {
        if model.statsRange == .week {
            HStack(spacing: 6) {
                ForEach(summary.cells) { cell in
                    VStack(spacing: 4) {
                        square(cell.level).frame(height: 26)
                        Text(Self.weekday(cell.date)).font(.mono(9)).foregroundStyle(Ink.faint)
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Activity on each of the last seven days")
        } else {
            let weeks = ClaudeStats.weeks(summary.cells)
            let labels = ClaudeStats.monthLabels(weeks)
            GeometryReader { area in
                let gap: CGFloat = weeks.count > 30 ? 1.5 : 3
                let side = max(2, min(14, (area.size.width - 26 - gap * CGFloat(weeks.count - 1)) / CGFloat(max(weeks.count, 1))))
                HStack(alignment: .top, spacing: 4) {
                    VStack(alignment: .leading, spacing: gap) {
                        Text(" ").font(.mono(8)).frame(height: 10)
                        ForEach(0..<7, id: \.self) { row in
                            Text(row == 0 ? "Mon" : row == 2 ? "Wed" : row == 4 ? "Fri" : "").font(.mono(8)).foregroundStyle(Ink.faint)
                                .frame(width: 22, height: side, alignment: .leading)
                        }
                    }
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                            VStack(spacing: gap) {
                                Text(labels[index]).font(.mono(8)).foregroundStyle(Ink.faint).fixedSize()
                                    .frame(width: side, height: 10, alignment: .leading)
                                ForEach(0..<7, id: \.self) { row in
                                    if let cell = week[row] { square(cell.level).frame(width: side, height: side) }
                                    else { Color.clear.frame(width: side, height: side) }
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: heatmapHeight(weeks: ClaudeStats.weeks(summary.cells).count))
            .accessibilityElement()
            .accessibilityLabel("Activity by day: \(summary.activeDays) active days out of \(summary.totalDays)")
        }
        HStack(spacing: 4) {
            Text("Less").font(.mono(9)).foregroundStyle(Ink.faint)
            ForEach(1...4, id: \.self) { level in square(level).frame(width: 9, height: 9) }
            Text("More").font(.mono(9)).foregroundStyle(Ink.faint)
        }
        .accessibilityHidden(true)
    }

    /// Fewer weeks get bigger squares, so the map always fills the panel's width.
    private func heatmapHeight(weeks: Int) -> CGFloat {
        let gap: CGFloat = weeks > 30 ? 1.5 : 3
        let side = max(2, min(14, (290 - 26 - gap * CGFloat(max(weeks - 1, 0))) / CGFloat(max(weeks, 1))))
        return 10 + 7 * side + 7 * gap
    }

    private func square(_ level: Int) -> some View {
        RoundedRectangle(cornerRadius: 2.5).fill(level == 0 ? Color.white.opacity(0.06) : Ink.gold.opacity(0.1 + Double(level) * 0.225))
    }

    private func fact(_ name: String, _ value: String, highlight: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.system(size: 12)).foregroundStyle(Ink.muted)
            Spacer(minLength: 10)
            Text(value).font(.mono(12, weight: highlight ? .semibold : .regular)).foregroundStyle(highlight ? Ink.gold : Ink.text)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: date)
    }

    private static func dayName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    private func meter(_ name: String, used: Double?, stop: Double, resets: Date?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: 13))
                Spacer()
                Text(used.map { "\(Int(($0 * 100).rounded()))%" } ?? "\u{2013}").font(.mono(18))
            }
            GeometryReader { area in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Ink.data).frame(width: max(0, area.size.width * (used ?? 0)))
                    Rectangle().fill(Ink.gold).frame(width: 2, height: 14).offset(x: area.size.width * stop - 1)
                }
            }
            .frame(height: 6)
            HStack {
                Text(resets.map { "resets \(Self.reset($0))" } ?? " ")
                Spacer()
                Text("OMNIS stops at \(Int(stop * 100))%")
            }
            .font(.mono(10)).foregroundStyle(Ink.faint)
        }
        .accessibilityElement(children: .combine)
    }

    private static func reset(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    private var system: some View {
        Panel(title: "SYSTEM") {
            row("Answering with", chat.usesLocal ? "the model on this Mac" : "Claude \u{00B7} \(chat.modelChoice.title)")
            row("Effort", chat.usesLocal ? "\u{2013}" : chat.effortChoice.title)
            row("Claude session", model.claudeSessionOpen ? "open" : "closed", dim: !model.claudeSessionOpen)
            row("Web search", chat.webEnabled ? "on" : "off", dim: !chat.webEnabled)
            row("Calendar", model.calendarAllowed ? "allowed" : "not allowed", dim: !model.calendarAllowed)
            row("Claude Code sessions", model.sessions.isEmpty ? "none running" : "\(model.sessions.count) running", dim: model.sessions.isEmpty)
            if let memory = model.memory {
                Rectangle().fill(Ink.line).frame(height: 1)
                row("Memory in use", memory.memoryLabel)
                row("Swap in use", memory.swapLabel, dim: memory.swapLabel == "none")
                HStack(alignment: .firstTextBaseline) {
                    Text("Memory pressure").font(.system(size: 13)).foregroundStyle(Ink.muted)
                    Spacer(minLength: 12)
                    Text(memory.pressure == .unknown ? "\u{2013}" : memory.pressure.rawValue).font(.mono(12))
                        .foregroundStyle(memory.pressure == .critical ? .red : memory.pressure == .warning ? .orange : Ink.text)
                }
                .accessibilityElement(children: .combine)
            }
            if !model.energy.isEmpty {
                Rectangle().fill(Ink.line).frame(height: 1)
                Text("USING THE MOST ENERGY").font(.mono(10)).foregroundStyle(Ink.faint)
                ForEach(model.energy) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name).font(.system(size: 13)).foregroundStyle(Ink.muted).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(String(format: "%.1f", item.impact)).font(.mono(12))
                            .foregroundStyle(item.impact >= 50 ? .orange : Ink.text)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.name), energy impact \(String(format: "%.0f", item.impact))")
                }
            }
        }
    }

    private func row(_ name: String, _ value: String, dim: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.system(size: 13)).foregroundStyle(Ink.muted)
            Spacer(minLength: 12)
            Text(value).font(.mono(12)).foregroundStyle(dim ? Ink.muted : Ink.text).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var activity: some View {
        Panel(title: "RECENT ACTIVITY") {
            if model.activity.isEmpty {
                Text("Nothing yet.").font(.system(size: 13)).foregroundStyle(Ink.faint)
            }
            ForEach(model.activity) { line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Self.short(line.time)).font(.mono(11)).foregroundStyle(Ink.faint).frame(width: 44, alignment: .leading)
                    Text(line.text).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private static func short(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM"
        return formatter.string(from: date)
    }

    // MARK: Bottom

    private var projects: some View {
        HStack(spacing: 12) {
            Text("PROJECTS").font(.mono(11)).tracking(1.5).foregroundStyle(Ink.muted)
            if model.projects.isEmpty && model.otherSessions.isEmpty {
                Text("Projects you open will appear here.").font(.system(size: 12)).foregroundStyle(Ink.faint)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.projects) { entry in
                        let session = model.session(for: entry)
                        HStack(spacing: 10) {
                            Text(entry.name).font(.system(size: 13, weight: .medium))
                            if let session {
                                Text("CLAUDE CODE RUNNING \u{00B7} \(session.age.uppercased())").font(.mono(10)).foregroundStyle(Ink.gold)
                            }
                            Button("Open") { model.launch(entry) }.buttonStyle(PillButton(compact: true))
                                .help("Open in \(chat.editorName)")
                                .accessibilityLabel("Open \(entry.name) in \(chat.editorName)")
                            Button("Work on it") { project.open(entry, resume: false) }.buttonStyle(PillButton(compact: true))
                                .help("Open in project mode, with Claude Code terminals")
                                .accessibilityLabel("Work on \(entry.name) in project mode")
                        }
                        .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
                    }
                    ForEach(model.otherSessions) { session in
                        HStack(spacing: 10) {
                            Text(session.project).font(.system(size: 13, weight: .medium))
                            Text("CLAUDE CODE RUNNING \u{00B7} \(session.age.uppercased())").font(.mono(10)).foregroundStyle(Ink.gold)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
    }
}

private struct PillButton: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13))
            .padding(.horizontal, compact ? 12 : 14).padding(.vertical, compact ? 6 : 8)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .contentShape(Capsule())
    }
}

/// The core: a slowly turning sphere of golden points whose surface ripples.
/// It swells and flares while OMNIS is answering. It is drawn only while the
/// dashboard is on screen.
struct CoreView: View, Animatable {
    var level: Double
    var running: Bool

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Points spread evenly over a sphere, with a fixed random value each.
    private static let points: [(x: Double, y: Double, z: Double, seed: Double)] = {
        let count = 2400
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<count).map { index in
            let y = 1 - (Double(index) / Double(count - 1)) * 2
            let radius = (1 - y * y).squareRoot()
            let angle = Double(index) * golden
            return (cos(angle) * radius, y, sin(angle) * radius, Double((index * 7919) % 97) / 97)
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !running || reduceMotion)) { timeline in
            Canvas { context, size in
                let t = reduceMotion ? 1.5 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
                let side = min(size.width, size.height)
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = side * 0.40
                let spin = t * 0.16, tilt = 0.38
                let cs = cos(spin), sn = sin(spin), ct = cos(tilt), st = sin(tilt)
                let amp = level * (0.85 + 0.3 * sin(t * 5) * sin(t * 1.7))
                for point in Self.points {
                    let wave = sin(3.1 * point.x + t * 1.3) * sin(2.3 * point.y - t * 0.9) * sin(2.7 * point.z + t * 0.7)
                    let x = point.x * cs + point.z * sn
                    var z = -point.x * sn + point.z * cs
                    let y = point.y * ct - z * st
                    z = point.y * st + z * ct
                    // Points near the edge flare outward, like a corona.
                    let rim = 1 - abs(z)
                    let flare = rim * rim * rim * (0.5 + 0.5 * sin(t * 1.7 + point.seed * 40)) * amp * 2.2
                    let reach = 1 + wave * amp + flare * point.seed
                    let depth = (z + 1) / 2
                    let dot = 0.6 + depth * 1.4 + flare * 2.2
                    let colour = point.seed > 0.9 ? Ink.goldLight : point.seed > 0.45 ? Ink.gold : Ink.goldDeep
                    let rect = CGRect(x: centre.x + x * reach * radius - dot / 2, y: centre.y + y * reach * radius - dot / 2,
                                      width: dot, height: dot)
                    context.fill(Path(ellipseIn: rect), with: .color(colour.opacity(min(1, 0.12 + depth * 0.75 + flare * 1.5))))
                }
            }
        }
    }
}
