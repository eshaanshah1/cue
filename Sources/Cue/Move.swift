import AppKit
import SwiftUI

// MARK: - Dragging a meeting to a new time

/// A meeting being dragged along the ribbon, and then waiting for Move or Propose.
/// Guests' busy time comes from Google's free/busy lookup, with this meeting's own slot taken out.
@MainActor
final class MoveModel: ObservableObject {
    let meeting: Meeting
    @Published private(set) var start: Date
    /// Let go of: the top of the popover asks to confirm.
    @Published var dropped = false
    @Published private(set) var busy: [String: FreeBusy]?
    @Published private(set) var saving = false
    @Published var error: String?

    private let store: CalendarStore

    init(meeting: Meeting, store: CalendarStore) {
        self.meeting = meeting
        self.store = store
        start = meeting.start
        let ids = guests.map(\.email)
        if ids.isEmpty { busy = [:] } else {
            Task { [weak self] in
                let result = await store.freeBusy(ids, day: meeting.start)
                self?.busy = result
            }
        }
    }

    /// Snapshot mode: wait for availability instead of drawing "Checking who’s free".
    func loadBusyNow() async {
        busy = await store.freeBusy(guests.map(\.email), day: meeting.start)
    }

    var duration: TimeInterval { meeting.end.timeIntervalSince(meeting.start) }
    var end: Date { start.addingTimeInterval(duration) }
    var day: Date { Calendar.current.startOfDay(for: meeting.start) }
    /// Yours to change; otherwise Cue can only ask the organiser.
    var isOwn: Bool { meeting.canModify }
    var guests: [Person] { meeting.people.filter { !$0.isSelf && !$0.resource } }
    var organizer: Person? { meeting.people.first { $0.organizer && !$0.isSelf } }
    /// A few guests get a lane each; more than that share one strip.
    var showsLanes: Bool { (1...4).contains(guests.count) }

    /// Snaps to the quarter hour and stays inside the ribbon, after now.
    func slide(to proposed: Date, lo: Double, hi: Double) {
        let t = (proposed.timeIntervalSinceReferenceDate / 900).rounded() * 900
        let earliest = max(day.addingTimeInterval(lo * 3600), Self.ceilQuarter(Clock.now()))
        let latest = day.addingTimeInterval(hi * 3600 - duration)
        let next = min(max(Date(timeIntervalSinceReferenceDate: t), earliest), max(earliest, latest))
        if next != start { start = next; error = nil }
    }

    func pick(_ s: Date) { start = s; error = nil }

    /// Busy blocks for one guest, without the meeting being moved. Nil when Google won't say.
    func blocks(_ p: Person) -> [DateInterval]? {
        guard let fb = busy?[p.email.lowercased()], !fb.unavailable else { return nil }
        let own = DateInterval(start: meeting.start, end: meeting.end)
        return fb.busy.flatMap { b -> [DateInterval] in
            guard b.intersects(own) else { return [b] }
            var out: [DateInterval] = []
            if b.start < own.start { out.append(DateInterval(start: b.start, end: own.start)) }
            if b.end > own.end { out.append(DateInterval(start: own.end, end: b.end)) }
            return out
        }
    }

    /// Times anyone else on the invite is busy, merged.
    var othersBusy: [DateInterval] {
        let all = guests.compactMap(blocks).flatMap { $0 }.sorted { $0.start < $1.start }
        var out: [DateInterval] = []
        for b in all {
            if let last = out.last, b.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, b.end))
            } else {
                out.append(b)
            }
        }
        return out
    }

    /// Who can't make it at a given start ("You" first).
    func conflicts(at s: Date) -> [String] {
        let e = s.addingTimeInterval(duration)
        func clashes(_ b: DateInterval) -> Bool { b.start < e && b.end > s }
        var out: [String] = []
        if store.meetings.contains(where: { $0.id != meeting.id && clashes(DateInterval(start: $0.start, end: $0.end)) }) {
            out.append("You")
        }
        for g in guests where blocks(g)?.contains(where: clashes) == true { out.append(g.firstName) }
        return out
    }

    var conflicts: [String] { conflicts(at: start) }

    /// The two nearest starts that suit everyone, earliest first.
    var suggestions: [Date] {
        let earliest = max(day.addingTimeInterval(8 * 3600), Self.ceilQuarter(Clock.now()))
        let latest = day.addingTimeInterval(20 * 3600 - duration)
        guard earliest <= latest else { return [] }
        let starts = stride(from: earliest.timeIntervalSinceReferenceDate, through: latest.timeIntervalSinceReferenceDate, by: 900)
            .map { Date(timeIntervalSinceReferenceDate: $0) }
            .filter { $0 != start && conflicts(at: $0).isEmpty }
        return Array(starts.sorted { abs($0.timeIntervalSince(start)) < abs($1.timeIntervalSince(start)) }.prefix(2)).sorted()
    }

    var title: String {
        let range = "\(Fmt.time(start)) – \(Fmt.time(end))"
        if !isOwn { return "Propose \(range)" }
        return dropped ? "Move to \(range)?" : "Move to \(range)"
    }

    func commit(_ model: AppModel) {
        guard start != meeting.start, !saving else { return }
        guard store.canWrite else { model.route = .permission; return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                if isOwn { try await store.move(meeting, to: start) } else { try await store.propose(meeting, start: start) }
                model.endMove()
            } catch GoogleError.needsWriteAccess {
                model.route = .permission
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private static func ceilQuarter(_ d: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / 900).rounded(.up) * 900)
    }
}

/// Takes the hero's place while a meeting is being moved: the new time, who can't make it,
/// and once it's dropped, Cancel and Move (or Propose).
struct MoveHero: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var move: MoveModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(move.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.cueBlue)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(move.meeting.title)
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.2)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
                if move.dropped {
                    HStack(spacing: 6) {
                        Button("Cancel") { model.endMove() }
                            .buttonStyle(SecondaryStyle(padding: 10))
                        Button(move.saving ? (move.isOwn ? "Moving…" : "Sending…") : (move.isOwn ? "Move" : "Propose")) { move.commit(model) }
                            .buttonStyle(JoinStyle(height: 28, size: 12, padding: 11))
                            .keyboardShortcut(.defaultAction)
                            .disabled(move.saving)
                    }
                    .fixedSize()
                }
            }
            status
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 20)
                .padding(.top, 3)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var status: some View {
        let conflicts = move.conflicts
        HStack(spacing: 6) {
            if let error = move.error {
                dot(.cueRed)
                Text(error).foregroundStyle(Color.cueRed)
            } else if move.busy == nil {
                dot(Color(nsColor: .systemGray))
                Text("Checking who’s free…")
            } else if !conflicts.isEmpty {
                dot(.cueRed)
                Text(busyText(conflicts) + (move.dropped && !move.suggestions.isEmpty ? ". Try" : ""))
                if move.dropped {
                    ForEach(move.suggestions, id: \.self) { s in
                        Button { move.pick(s) } label: {
                            Text(Fmt.time(s)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Color.cueBlue)
                                .padding(.horizontal, 8)
                                .frame(height: 20)
                                .overlay(Capsule().strokeBorder(Color.cueBlue.opacity(0.45), lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                dot(Color(nsColor: .systemGreen))
                Text(freeText)
            }
        }
        .monospacedDigit()
    }

    private func dot(_ c: Color) -> some View { Circle().fill(c).frame(width: 7, height: 7) }

    private func busyText(_ names: [String]) -> String {
        if names == ["You"] { return "You’re busy then" }
        switch names.count {
        case 1: return "\(names[0])’s busy then"
        case 2: return "\(names[0]) and \(names[1]) are busy then"
        default: return "\(names[0]) and \(names.count - 1) others are busy"
        }
    }

    private var freeText: String {
        let n = move.guests.count
        let base = n == 0 ? "You’re free then" : n == 1 ? "\(move.guests[0].firstName)’s free then" : "Everyone’s free"
        guard move.dropped else { return base }
        if !move.isOwn { return base + " · asks \(move.organizer?.firstName ?? "the organiser")" }
        return n == 0 ? base : base + " · emails \(n == 1 ? move.guests[0].firstName : "\(n) guests")"
    }
}

/// Under the ribbon while moving: a lane per guest, or one strip when there are five or more.
struct MoveLanes: View {
    @ObservedObject var move: MoveModel
    let x: (Date) -> CGFloat
    let lo: Double
    let hi: Double

    static let laneH: CGFloat = 11, gap: CGFloat = 3
    static let colors: [NSColor] = [.systemOrange, .systemIndigo, .systemGreen, .systemPink]

    /// Extra height the ribbon needs below the track.
    static func extra(_ move: MoveModel?) -> CGFloat {
        guard let move, !move.guests.isEmpty else { return 0 }
        return move.showsLanes ? CGFloat(move.guests.count) * (laneH + gap) - gap + 4 : 8
    }

    var body: some View {
        let dayLo = move.day.addingTimeInterval(lo * 3600), dayHi = move.day.addingTimeInterval(hi * 3600)
        if move.showsLanes {
            ForEach(Array(move.guests.enumerated()), id: \.element.email) { i, p in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3.5).fill(Color.primary.opacity(0.07))
                    ForEach(Array((move.blocks(p) ?? []).enumerated()), id: \.offset) { _, b in
                        let s = max(b.start, dayLo), e = min(b.end, dayHi)
                        if e > s {
                            Hatch(color: Color(nsColor: Self.colors[i % Self.colors.count]), radius: 3, spacing: 5, line: 2)
                                .frame(width: max(2, x(e) - x(s) - 1), height: Self.laneH)
                                .offset(x: x(s))
                        }
                    }
                    Text(move.blocks(p) == nil && move.busy != nil ? "\(p.firstName) · not shared" : p.firstName)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 4)
                        .frame(height: Self.laneH)
                }
                .frame(height: Self.laneH)
                .offset(y: 22 + CGFloat(i) * (Self.laneH + Self.gap))
            }
            let bad = !move.conflicts.isEmpty
            let tint = bad ? Color.cueRed : Color.cueBlue
            RoundedRectangle(cornerRadius: 7)
                .fill(tint.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                .frame(width: max(6, x(move.end) - x(move.start) + 2), height: 24 + CGFloat(move.guests.count) * (Self.laneH + Self.gap))
                .offset(x: x(move.start) - 2, y: -3)
                .allowsHitTesting(false)
        } else if !move.guests.isEmpty {
            // Green where every guest is free, striped where anyone's busy. Nothing before now.
            let from = max(dayLo, Clock.now())
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.primary.opacity(0.07))
                if move.busy != nil {
                    ForEach(Array(segments(from: from, to: dayHi).enumerated()), id: \.offset) { _, seg in
                        Group {
                            if seg.busy {
                                Hatch(color: .secondary, radius: 0, spacing: 4, line: 1.5, outlined: false)
                            } else {
                                Rectangle().fill(Color(nsColor: .systemGreen).opacity(0.7))
                            }
                        }
                        .frame(width: max(1, x(seg.end) - x(seg.start)), height: 5)
                        .offset(x: x(seg.start))
                    }
                }
            }
            .frame(height: 5)
            .clipShape(Capsule())
            .offset(y: 21)
        }
    }

    private func segments(from: Date, to: Date) -> [(start: Date, end: Date, busy: Bool)] {
        var out: [(Date, Date, Bool)] = []
        var cursor = from
        for b in move.othersBusy where b.end > cursor {
            if b.start >= to { break }
            if b.start > cursor { out.append((cursor, b.start, false)) }
            out.append((max(b.start, cursor), min(b.end, to), true))
            cursor = b.end
        }
        if cursor < to { out.append((cursor, to, false)) }
        return out.map { (start: $0.0, end: $0.1, busy: $0.2) }
    }
}
