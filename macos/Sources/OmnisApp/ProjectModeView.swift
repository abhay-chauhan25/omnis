import OmnisCore
import SwiftUI

private enum Tone {
    static let text = Color(red: 0.91, green: 0.93, blue: 0.95)
    static let muted = Color(red: 0.60, green: 0.65, blue: 0.71)
    static let faint = Color(red: 0.49, green: 0.54, blue: 0.59)
    static let gold = Color(red: 0.949, green: 0.757, blue: 0.306)
    static let line = Color.white.opacity(0.08)
    static let panel = Color.white.opacity(0.025)
    static let terminal = Color(red: 0.035, green: 0.043, blue: 0.058)
}

/// Project mode: the terminals on the left, OMNIS as an advisor on the right.
struct ProjectModeView: View {
    @ObservedObject var model: ProjectModeModel

    var body: some View {
        if !model.available {
            message("Claude Code was not found on this Mac, so project mode cannot start a session.")
        } else if model.projects.isEmpty {
            message("No projects yet. Ask OMNIS to \u{201C}set up a project called \u{2026}\u{201D}, or add a folder to your projects folder.")
        } else {
            HStack(alignment: .top, spacing: 18) {
                terminals.frame(maxWidth: .infinity, maxHeight: .infinity)
                side.frame(width: 340)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(Tone.muted).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    // MARK: Terminals

    private var terminals: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(model.projects) { project in
                        Button(project.name) { model.select(project) }
                    }
                } label: {
                    Text(model.selected?.name ?? "Choose a project").font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Project: \(model.selected?.name ?? "none")")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.visibleTabs) { tab in
                            let current = tab.id == model.currentTab?.id
                            HStack(spacing: 6) {
                                Circle().fill(tab.ended ? Tone.faint : Tone.gold).frame(width: 6, height: 6)
                                Text(tab.title).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                Button { model.close(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                    .buttonStyle(.plain).foregroundStyle(Tone.faint)
                                    .help(tab.ended ? "Close this tab" : "End this session and close the tab")
                                    .accessibilityLabel("Close \(tab.title)")
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(current ? Color.white.opacity(0.10) : Color.white.opacity(0.03)))
                            .contentShape(Capsule())
                            .onTapGesture { model.activeTab = tab.id }
                            .accessibilityAddTraits(current ? .isSelected : [])
                        }
                    }
                }
                Spacer(minLength: 8)
                Button { model.openTerminal() } label: { Label("New session", systemImage: "plus") }
                    .help("Start a new Claude Code session in this project")
                Button("From a brief\u{2026}") { model.showBrief = true }
                    .help("Write what you want built, and start a session with it as the first message")
                    .popover(isPresented: $model.showBrief, arrowEdge: .bottom) { briefEditor }
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Tone.muted)
            .padding(.horizontal, 12).padding(.vertical, 8)

            Rectangle().fill(Tone.line).frame(height: 1)

            if let tab = model.currentTab {
                TerminalHost(view: tab.view).id(tab.id).padding(8)
            } else {
                VStack(spacing: 14) {
                    Text("No session open for \(model.selected?.name ?? "this project").").font(.system(size: 14)).foregroundStyle(Tone.muted)
                    HStack(spacing: 10) {
                        Button("New session") { model.openTerminal() }.buttonStyle(Chip(strong: true))
                        Button("Resume the last one") { model.openTerminal(resume: true) }.buttonStyle(Chip())
                        Button("Start from a brief\u{2026}") { model.showBrief = true }.buttonStyle(Chip())
                    }
                    Text("A session is your own Claude Code, started in this project's folder. OMNIS adds no rules: it asks you, or doesn't, exactly as it does in your own terminal.")
                        .font(.system(size: 12)).foregroundStyle(Tone.faint).multilineTextAlignment(.center).frame(maxWidth: 440)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Tone.terminal))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tone.line))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var briefEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should be built?").font(.system(size: 13, weight: .semibold))
            TextEditor(text: $model.brief).font(.system(size: 13)).frame(width: 420, height: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12)))
                .accessibilityLabel("Brief")
            Text("This becomes the first message of a new session. You can ask the advisor to help you write it first.")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 420, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") { model.showBrief = false }
                Button("Start session") { model.startFromBrief() }.buttonStyle(.borderedProminent)
                    .disabled(model.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: Advisor

    private var side: some View {
        VStack(alignment: .leading, spacing: 12) {
            box("WHAT THE SESSION IS DOING") {
                if let activity = model.activity {
                    if let title = activity.title { Text(title).font(.system(size: 13, weight: .medium)).lineLimit(2) }
                    ForEach(Array(activity.steps.suffix(5).enumerated()), id: \.offset) { _, step in
                        Text(step).font(.system(size: 12)).foregroundStyle(Tone.muted).lineLimit(2)
                    }
                    ForEach(activity.tasks.prefix(8)) { task in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: task.state == "completed" ? "checkmark.circle.fill" : task.state == "in_progress" ? "circle.dotted" : "circle")
                                .font(.system(size: 10)).foregroundStyle(task.state == "pending" ? Tone.faint : Tone.gold)
                            Text(task.text).font(.system(size: 12)).lineLimit(2)
                        }
                    }
                } else {
                    Text("Nothing recorded yet.").font(.system(size: 12)).foregroundStyle(Tone.faint)
                }
            }
            if !model.changedFiles.isEmpty {
                box("CHANGED FILES \u{00B7} \(model.changedFiles.count)") {
                    ForEach(model.changedFiles.prefix(8), id: \.self) { file in
                        Text(file).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tone.muted).lineLimit(1).truncationMode(.head)
                    }
                    if model.changedFiles.count > 8 {
                        Text("and \(model.changedFiles.count - 8) more").font(.system(size: 11)).foregroundStyle(Tone.faint)
                    }
                }
            }
            advisor
        }
    }

    private var advisor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OMNIS ADVISOR").font(.system(size: 11, design: .monospaced)).tracking(1.5).foregroundStyle(Tone.muted)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.advisor.isEmpty {
                            Text("Ask about this project while the session works: what a file does, whether an approach is sound, what the session is doing, or for help writing a prompt. The advisor can read this project's files. It cannot change anything.")
                                .font(.system(size: 12)).foregroundStyle(Tone.faint).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.advisor) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.fromUser ? "YOU" : "OMNIS").font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(message.fromUser ? Tone.faint : Tone.gold)
                                Text(message.text.isEmpty ? "\u{2026}" : message.text).font(.system(size: 13))
                                    .foregroundStyle(message.failed ? Tone.muted : Tone.text)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if !message.fromUser, !message.failed, !message.text.isEmpty, !(model.advisorBusy && message.id == model.advisor.last?.id) {
                                    Button("Put in terminal") { model.placeInTerminal(ProjectModeModel.prompt(in: message.text)) }
                                        .buttonStyle(Chip())
                                        .help("Places this in the terminal's input for you to read and send. It is not sent for you.")
                                }
                            }
                            .id(message.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.advisor) { if let last = model.advisor.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundStyle(Tone.muted) }
            HStack(spacing: 8) {
                TextField("Ask OMNIS about this project", text: $model.question, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                    .onSubmit { model.askAdvisor() }
                    .accessibilityLabel("Ask the advisor")
                Button { model.askAdvisor() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.black)
                        .frame(width: 26, height: 26).background(Circle().fill(Tone.gold))
                }
                .buttonStyle(.plain)
                .disabled(model.advisorBusy || model.question.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Ask")
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Tone.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tone.line))
    }

    private func box<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, design: .monospaced)).tracking(1.5).foregroundStyle(Tone.muted)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Tone.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tone.line))
    }
}

private struct Chip: ButtonStyle {
    var strong = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12))
            .foregroundStyle(strong ? Color.black : Tone.text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(strong ? Tone.gold : Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .contentShape(Capsule())
    }
}
