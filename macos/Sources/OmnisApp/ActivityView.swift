import AppKit
import OmnisCore
import SwiftUI

/// The dashboard's Activity mode: everything OMNIS has recorded about what
/// it did, newest first. It shows names, counts and outcomes only, because
/// that is all the record holds.
struct ActivityView: View {
    @ObservedObject var model: DashboardModel
    @State private var filter: ActivityLog.Filter = .all
    @State private var search = ""

    private var days: [ActivityLog.Day] {
        ActivityLog.days(model.activityRows, filter: filter, matching: search, now: model.now)
    }

    var body: some View {
        // Worked out once for each drawing of the view.
        let days = self.days
        return VStack(alignment: .leading, spacing: 14) {
            controls
            list(days)
            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text("ACTIVITY").font(.mono(11)).tracking(1.5).foregroundStyle(Ink.muted)
            HStack(spacing: 2) {
                ForEach(ActivityLog.Filter.allCases, id: \.self) { choice in
                    Button(choice.rawValue) { filter = choice }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: filter == choice ? .semibold : .regular))
                        .foregroundStyle(filter == choice ? Ink.ground : Ink.muted)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(filter == choice ? Ink.gold : .clear))
                        .contentShape(Capsule())
                        .accessibilityAddTraits(filter == choice ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Show")
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Ink.faint)
                TextField("Filter", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 13)).frame(width: 200)
                    .accessibilityLabel("Filter the activity list")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(Ink.faint).accessibilityLabel("Clear the filter")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
        }
    }

    @ViewBuilder private func list(_ days: [ActivityLog.Day]) -> some View {
        if days.isEmpty {
            Text(model.activityRows.isEmpty ? "Nothing has been recorded yet." : "Nothing matches.")
                .font(.system(size: 13)).foregroundStyle(Ink.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(days) { day in
                        Text(day.title.uppercased()).font(.mono(10)).tracking(1.2).foregroundStyle(Ink.faint)
                            .padding(.top, 14).padding(.bottom, 6)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(day.rows) { row in
                            line(row)
                            Rectangle().fill(Ink.line).frame(height: 1)
                        }
                    }
                }
                .padding(.trailing, 6)
            }
        }
    }

    private func line(_ row: ActivityLog.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(Self.clock(row.time)).font(.mono(11)).foregroundStyle(Ink.faint).frame(width: 44, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.title).font(.system(size: 13)).lineLimit(1)
                if row.count > 1 {
                    Text("\u{00D7}\(row.count)").font(.mono(11)).foregroundStyle(Ink.faint)
                        .accessibilityLabel("\(row.count) times")
                }
            }
            .frame(minWidth: 220, maxWidth: 420, alignment: .leading)
            Text(row.outcome).font(.mono(11)).foregroundStyle(Self.colour(row.tone)).lineLimit(1)
                .frame(width: 130, alignment: .leading)
            Text(row.detail).font(.system(size: 12)).foregroundStyle(Ink.muted).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.detail)
        }
        .padding(.vertical, 7)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Names, counts and outcomes only. What you type and what is read are never recorded.")
                .font(.system(size: 11)).foregroundStyle(Ink.faint)
            Spacer(minLength: 12)
            Text(model.activityRecords == 1 ? "Latest 1 record" : "Latest \(model.activityRecords) records").font(.mono(11)).foregroundStyle(Ink.faint)
            Button("Show File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([OmnisPaths.auditLog]) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Ink.text)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
                .contentShape(Capsule())
        }
    }

    private static func colour(_ tone: ActivityLog.Tone) -> Color {
        switch tone {
        case .plain: return Ink.muted
        case .changed: return Ink.gold
        case .stopped: return .orange
        }
    }

    private static let clockFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func clock(_ date: Date) -> String { clockFormat.string(from: date) }
}
