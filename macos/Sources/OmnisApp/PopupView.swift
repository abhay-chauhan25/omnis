import AppKit
import OmnisCore
import SwiftUI

/// The centre bar: a text field, live results, and an area for answers.
struct PopupView: View {
    @ObservedObject var model: PopupModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let barWidth: CGFloat = 680
    static let margin: CGFloat = 20
    private static let corner: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            bar
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
                .scaleEffect(model.visible || reduceMotion ? 1 : 0.97, anchor: .top)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.visible)
            Spacer(minLength: 0)
        }
        .padding(Self.margin)
        .frame(width: Self.barWidth + Self.margin * 2)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .onChange(of: model.openCount) { focusField() }
        .onAppear { focusField() }
    }

    private func focusField() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    private var bar: some View {
        VStack(spacing: 0) {
            field
            switch model.phase {
            case .input:
                if !model.rows.isEmpty {
                    Divider()
                    results
                }
            case .answering(let text, let finished, let modelName):
                Divider()
                answer(text: text, finished: finished, modelName: modelName)
            case .failed(let message):
                Divider()
                failure(message)
            }
            if !model.notices.isEmpty, model.phase == .input {
                Divider()
                noticeFooter
            }
        }
        .frame(width: Self.barWidth)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Open an app or project, or ask a question", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($fieldFocused)
                .onSubmit { model.runSelected() }
                .accessibilityLabel("OMNIS command")
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    // MARK: Results

    private var results: some View {
        VStack(spacing: 2) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                ResultRow(row: row, editorName: model.editorName, selected: index == model.selection)
                    .contentShape(Rectangle())
                    .onTapGesture { model.run(row) }
                    .accessibilityAction { model.run(row) }
            }
        }
        .padding(8)
    }

    // MARK: Answer

    private func answer(text: String, finished: Bool, modelName: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if !finished {
                    ProgressView().controlSize(.small)
                    Text("Answering").foregroundStyle(.secondary)
                } else if let modelName {
                    Text(modelName == "mock" ? "Mock reply, no model used" : "Answered by \(modelName)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("esc to close").foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(finished ? "Answer: \(text)" : "Answering")
    }

    private func failure(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Problem: \(message)")
    }

    private var noticeFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.notices, id: \.self) { notice in
                Text(notice).lineLimit(2)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}

private struct ResultRow: View {
    let row: PopupModel.Row
    let editorName: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 28, height: 28)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Text(kindLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.12 : 0))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(kindLabel)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var title: String {
        switch row {
        case .entry(let entry): return entry.name
        case .ask(let text): return "Ask OMNIS: \(text)"
        }
    }

    private var kindLabel: String {
        switch row {
        case .entry(let entry):
            switch entry.kind {
            case .app: return "App"
            case .project: return "Project in \(editorName)"
            case .launcher: return "Launcher"
            }
        case .ask: return "Question"
        }
    }

    @ViewBuilder private var icon: some View {
        switch row {
        case .entry(let entry) where entry.kind != .launcher:
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .interpolation(.high)
                .accessibilityHidden(true)
        case .entry:
            symbol("terminal")
        case .ask:
            symbol("sparkles")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}
