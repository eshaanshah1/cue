import AppKit
import SwiftUI

// MARK: - Parsing "Design sync with Priya tomorrow at 3pm 45m"

struct ParsedEvent {
    var title = ""
    /// Ranges in the text that Cue understood, tinted blue in the field.
    var tokens: [NSRange] = []
    var date: Date?
    var hasTime = false
    var minutes: Int?
    var people: [Person] = []
    /// Words after "with" that look like names but aren't anyone Cue knows yet.
    var unknownNames: [String] = []
}

enum NLParser {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let duration = try! NSRegularExpression(
        pattern: #"\b(?:for\s+)?(\d+(?:\.\d+)?)\s*(hours|hour|hrs|hr|h|minutes|minute|mins|min|m)\b|\b(?:for\s+)?(half an hour|an hour)\b"#,
        options: .caseInsensitive)
    private static let email = try! NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: .caseInsensitive)
    private static let timeHint = try! NSRegularExpression(pattern: #"\d|noon|midnight|morning|afternoon|evening|tonight"#, options: .caseInsensitive)
    private static let with = try! NSRegularExpression(pattern: #"\bwith\s+"#, options: .caseInsensitive)
    private static let word = try! NSRegularExpression(pattern: #"[\p{L}\p{N}@._'-]+|,|&"#)
    private static let connectors: Set<String> = ["with", "and", "at", "on", "for", "&", ",", "from"]

    static func parse(_ text: String, contacts: [Person]) -> ParsedEvent {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var out = ParsedEvent()
        var drop: [NSRange] = []

        for m in duration.matches(in: text, range: all) {
            if m.range(at: 1).location != NSNotFound {
                let n = Double(ns.substring(with: m.range(at: 1))) ?? 0
                out.minutes = Int(ns.substring(with: m.range(at: 2)).lowercased().hasPrefix("h") ? n * 60 : n)
                out.tokens.append(NSUnionRange(m.range(at: 1), m.range(at: 2)))
            } else {
                out.minutes = ns.substring(with: m.range(at: 3)).lowercased().hasPrefix("half") ? 30 : 60
                out.tokens.append(m.range(at: 3))
            }
            drop.append(m.range)
        }

        for m in email.matches(in: text, range: all) {
            let e = ns.substring(with: m.range)
            out.people.append(contacts.first { $0.email.caseInsensitiveCompare(e) == .orderedSame } ?? Person(email: e))
            out.tokens.append(m.range)
            drop.append(m.range)
        }

        // Dates are detected with durations and emails blanked out, so "45m" isn't read as a time.
        if let m = detector.firstMatch(in: masked(text, drop), range: all), let d = m.date {
            let sub = ns.substring(with: m.range)
            out.hasTime = timeHint.firstMatch(in: sub, range: NSRange(location: 0, length: (sub as NSString).length)) != nil
            out.date = d
            if m.duration > 0, out.minutes == nil { out.minutes = Int(m.duration / 60) }
            out.tokens.append(trimmedLeadingConnector(m.range, ns))
            drop.append(m.range)
        }

        if let w = with.firstMatch(in: text, range: all) {
            let start = NSMaxRange(w.range)
            let words = word.matches(in: text, range: NSRange(location: start, length: ns.length - start)).map(\.range)
            var i = 0
            var found: [NSRange] = []
            while i < words.count {
                let r = words[i]
                let lw = ns.substring(with: r).lowercased()
                if lw == "and" || lw == "&" || lw == "," { i += 1; continue }
                if drop.contains(where: { NSIntersectionRange($0, r).length > 0 }) {
                    if lw.contains("@") { i += 1; continue } // an email, already added
                    break                                     // reached the date
                }
                if i + 1 < words.count, let p = match(lw + " " + ns.substring(with: words[i + 1]).lowercased(), contacts) {
                    add(p, &out.people)
                    found.append(NSUnionRange(r, words[i + 1]))
                    i += 2
                } else if let p = match(lw, contacts) {
                    add(p, &out.people)
                    found.append(r)
                    i += 1
                } else {
                    // Only the first word of each name slot counts, so "with Sanket about Q4" asks about Sanket.
                    let prev = i == 0 ? "with" : ns.substring(with: words[i - 1]).lowercased()
                    if ["with", "and", "&", ","].contains(prev), lw.count >= 2, !connectors.contains(lw) {
                        out.unknownNames.append(ns.substring(with: r))
                        i += 1
                        continue
                    }
                    break
                }
            }
            if !found.isEmpty {
                out.tokens += found
                drop.append(w.range)
                drop += found
            }
        }

        out.title = cleanTitle(masked(text, drop))
        return out
    }

    private static func match(_ q: String, _ contacts: [Person]) -> Person? {
        guard q.count >= 2 else { return nil }
        return contacts.first { p in
            let name = (p.name ?? "").lowercased()
            let local = p.email.lowercased().split(separator: "@").first.map(String.init) ?? ""
            return name == q || name.hasPrefix(q + " ") || (q.count >= 3 && (name.hasPrefix(q) || local.hasPrefix(q)))
        }
    }

    private static func add(_ p: Person, _ list: inout [Person]) {
        if !list.contains(where: { $0.email.caseInsensitiveCompare(p.email) == .orderedSame }) { list.append(p) }
    }

    private static func masked(_ text: String, _ ranges: [NSRange]) -> String {
        let s = NSMutableString(string: text)
        for r in ranges where NSMaxRange(r) <= s.length {
            s.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
        }
        return s as String
    }

    /// Tint "tomorrow at 3pm" but not a leading "at" or "on".
    private static func trimmedLeadingConnector(_ r: NSRange, _ ns: NSString) -> NSRange {
        let sub = ns.substring(with: r)
        for c in ["at ", "on ", "from "] where sub.lowercased().hasPrefix(c) {
            return NSRange(location: r.location + c.count, length: r.length - c.count)
        }
        return r
    }

    private static func cleanTitle(_ s: String) -> String {
        var words = s.split(whereSeparator: \.isWhitespace).map(String.init)
        while let last = words.last, connectors.contains(last.lowercased()) { words.removeLast() }
        while let first = words.first, connectors.contains(first.lowercased()), words.count > 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }
}

// MARK: - Compose state

@MainActor
final class ComposeModel: ObservableObject {
    @Published var text = "" { didSet { if text != oldValue { reparse() } } }
    @Published private(set) var parsed = ParsedEvent()
    @Published var dayOverride: Date? { didSet { refreshBusy() } }
    @Published var startOverride: Date? { didSet { refreshBusy() } }
    @Published var minutesOverride: Int?
    @Published var meet = true
    @Published var calendarID: String?
    @Published var extraPeople: [Person] = [] { didSet { refreshBusy() } }
    @Published var removed: Set<String> = [] { didSet { refreshBusy() } }
    @Published private(set) var busy: [String: FreeBusy] = [:]
    @Published var saving = false
    @Published var error: String?

    private let store: CalendarStore
    private var busyTask: Task<Void, Never>?
    private var lastBusyKey = ""

    init(store: CalendarStore) {
        self.store = store
        refreshBusy()
    }

    /// Names after "with" that don't match anyone in your recent meetings.
    var notFound: [String] { parsed.unknownNames }

    private func reparse() {
        parsed = NLParser.parse(text, contacts: store.contacts)
        refreshBusy()
    }

    // MARK: Derived

    var people: [Person] {
        var seen = Set<String>()
        return (parsed.people + extraPeople).filter {
            let e = $0.email.lowercased()
            return !removed.contains(e) && seen.insert(e).inserted
        }
    }

    var title: String {
        if !parsed.title.isEmpty { return parsed.title }
        return people.isEmpty ? "" : "Meeting with \(Fmt.people(people.map(\.display)))"
    }

    var minutes: Int { max(5, minutesOverride ?? parsed.minutes ?? 30) }

    private var cal: Calendar { Calendar.current }

    /// The typed time, moved to tomorrow if it's already passed and no day was given.
    private var parsedStart: Date? {
        guard parsed.hasTime, var d = parsed.date else { return nil }
        if d < Clock.now(), !text.lowercased().contains("today") { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
        return d
    }

    var day: Date {
        if let s = startOverride { return cal.startOfDay(for: s) }
        if let d = dayOverride { return cal.startOfDay(for: d) }
        if let s = parsedStart { return cal.startOfDay(for: s) }
        if let d = parsed.date { return cal.startOfDay(for: d) }
        let now = Clock.now()
        let late = cal.component(.hour, from: now) >= 17
        return cal.startOfDay(for: late ? cal.date(byAdding: .day, value: 1, to: now)! : now)
    }

    /// What the person asked for, if anything. Otherwise Cue picks the first free slot.
    var requestedStart: Date? {
        if let s = startOverride { return s }
        guard let s = parsedStart else { return nil }
        guard dayOverride != nil else { return s }
        let c = cal.dateComponents([.hour, .minute], from: s)
        return cal.date(bySettingHour: c.hour ?? 9, minute: c.minute ?? 0, second: 0, of: day)
    }

    var start: Date? { requestedStart ?? suggestions.first }
    var end: Date? { start.map { $0.addingTimeInterval(TimeInterval(minutes * 60)) } }

    var laneIDs: [String] { [store.primaryCalendarID.lowercased()] + people.map { $0.email.lowercased() } }

    private func hour(_ h: Double) -> Date { day.addingTimeInterval(h * 3600) }

    private var allBusy: [DateInterval] {
        laneIDs.compactMap { busy[$0] }.filter { !$0.unavailable }.flatMap(\.busy).sorted { $0.start < $1.start }
    }

    /// Who's busy at the chosen time ("You" first).
    var conflicts: [String] {
        guard let s = start, let e = end else { return [] }
        let slot = DateInterval(start: s, end: e)
        return laneIDs.enumerated().compactMap { i, id in
            guard let fb = busy[id], fb.busy.contains(where: { $0.intersects(slot) && $0.end != s && $0.start != e }) else { return nil }
            return i == 0 ? "You" : people[i - 1].firstName
        }
    }

    /// Stretches where everyone is free, long enough for the meeting.
    func freeRanges(from lo: Double, to hi: Double) -> [DateInterval] {
        let now = Clock.now()
        var cursor = max(hour(lo), ceilQuarter(now))
        let limit = hour(hi)
        var out: [DateInterval] = []
        for b in allBusy {
            if b.end <= cursor { continue }
            if b.start >= limit { break }
            if b.start > cursor { out.append(DateInterval(start: cursor, end: min(b.start, limit))) }
            cursor = max(cursor, b.end)
        }
        if cursor < limit { out.append(DateInterval(start: cursor, end: limit)) }
        return out.filter { $0.duration >= TimeInterval(minutes * 60) }
    }

    /// Up to three free starts in working hours, nearest to the asked-for time when it clashes.
    var suggestions: [Date] {
        let len = TimeInterval(minutes * 60)
        var candidates: [Date] = []
        for r in freeRanges(from: 9, to: 19) {
            let first = ceilQuarter(r.start)
            if first.addingTimeInterval(len) <= r.end { candidates.append(first) }
            // When the asked-for time clashes, the latest start before it is often the closest fit.
            let last = floorQuarter(r.end.addingTimeInterval(-len))
            if requestedStart != nil, last > first, last >= r.start { candidates.append(last) }
        }
        if let want = requestedStart {
            candidates.sort { abs($0.timeIntervalSince(want)) < abs($1.timeIntervalSince(want)) }
        }
        var seen = Set<Date>()
        return Array(candidates.filter { seen.insert($0).inserted }.prefix(3))
    }

    var canCreate: Bool { !title.isEmpty && start != nil && !saving }

    private func ceilQuarter(_ d: Date) -> Date {
        let t = d.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 900).rounded(.up) * 900)
    }

    private func floorQuarter(_ d: Date) -> Date {
        let t = d.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 900).rounded(.down) * 900)
    }

    // MARK: Actions

    func refreshBusy() {
        let ids = laneIDs
        let d = day
        let key = ids.joined(separator: ",") + "|\(d.timeIntervalSince1970)"
        guard key != lastBusyKey else { return }
        lastBusyKey = key
        busyTask?.cancel()
        busyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            let result = await self.store.freeBusy(ids, day: d)
            guard !Task.isCancelled else { return }
            self.busy = result
        }
    }

    func pick(_ s: Date) { startOverride = s }

    /// Snapshot mode: load availability right away instead of after the typing pause.
    func loadBusyNow() async {
        busy = await store.freeBusy(laneIDs, day: day)
    }

    func create() async -> Bool {
        guard canCreate, let s = start, let e = end else { return false }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await store.create(.init(title: title, start: s, end: e, attendees: people, meet: meet, notes: nil), calendarID: calendarID)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

// MARK: - Compose view

struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var c: ComposeModel

    static let laneColors: [NSColor] = [.systemOrange, .systemIndigo, .systemGreen, .systemPink, .systemTeal]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if Snapshot.active {
                    Snapshot.tinted(c.text, c.parsed.tokens, size: 15).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TokenField(text: $c.text, tokens: c.parsed.tokens,
                               placeholder: "Sync with Priya tomorrow at 3pm",
                               onSubmit: create, onCancel: { model.route = .main })
                }
            }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.fill))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.cueBlue.opacity(0.65), lineWidth: 1.5))
                .padding(.horizontal, 12)

            FlowLayout(spacing: 6) { chips }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)

            HStack {
                Text(dayName(c.day)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(laneCaption).font(.system(size: 12)).foregroundStyle(Color.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            LanesView(c: c, mine: model.meetings.filter { Calendar.current.isDate($0.start, inSameDayAs: c.day) })
                .padding(.horizontal, 16)

            hint.padding(.horizontal, 16).padding(.top, 10)

            HStack {
                Text(footnote).font(.system(size: 12)).foregroundStyle(Color.tertiary).lineLimit(1)
                Spacer()
                Button("Cancel") { model.cancelCompose() }.buttonStyle(SecondaryStyle(height: 30, size: 13, padding: 14))
                Button(action: create) {
                    HStack(spacing: 4) {
                        Text(c.saving ? "Creating…" : "Create")
                        Text("⌘↩").font(.system(size: 11, weight: .medium)).opacity(0.75)
                    }
                }
                .buttonStyle(JoinStyle(height: 30, size: 13, padding: 14))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!c.canCreate)
                .opacity(c.canCreate ? 1 : 0.5)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
        .padding(.top, 12)
    }

    private func create() {
        Task { if await c.create() { model.finishCompose() } }
    }

    private var laneCaption: String {
        switch c.people.count {
        case 0: return "Your day"
        case 1: return "Your day and \(c.people[0].firstName)’s"
        default: return "Green is when everyone’s free"
        }
    }

    private var footnote: String {
        if let e = c.error { return e }
        if c.people.isEmpty { return "Only on your calendar" }
        return "Invites \(Fmt.people(c.people.map(\.display))) by email"
    }

    private func dayName(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.wide))
    }

    @ViewBuilder private var chips: some View {
        Chip(icon: "calendar", text: relativeDay(c.day)) {
            PopMenu.show((0..<7).map { i in
                let d = Calendar.current.date(byAdding: .day, value: i, to: Calendar.current.startOfDay(for: Clock.now()))!
                return .init(relativeDay(d), checked: Calendar.current.isDate(d, inSameDayAs: c.day)) {
                    if let s = c.start {
                        let hm = Calendar.current.dateComponents([.hour, .minute], from: s)
                        c.startOverride = Calendar.current.date(bySettingHour: hm.hour!, minute: hm.minute!, second: 0, of: d)
                    } else {
                        c.dayOverride = d
                    }
                }
            })
        }
        Chip(icon: "clock", text: timeText) {
            var items: [PopMenu.Item] = [20, 30, 45, 60, 90].map { m in
                .init(m < 60 ? "\(m) min" : m == 60 ? "1 hour" : "1.5 hours", checked: c.minutes == m) { c.minutesOverride = m }
            }
            items.append(.separator)
            for s in c.suggestions { items.append(.init("Start at \(Fmt.time(s))") { c.pick(s) }) }
            PopMenu.show(items)
        }
        ForEach(Array(c.people.enumerated()), id: \.element.email) { i, p in
            Chip(avatar: (Fmt.initials(p.display), Self.laneColors[i % Self.laneColors.count]), text: p.display) {
                var items: [PopMenu.Item] = [.init(p.email) {}]
                items.append(.init("Remove \(p.firstName)") { c.removed.insert(p.email.lowercased()) })
                PopMenu.show(items)
            }
        }
        Chip(icon: c.meet ? "video" : "video.slash", text: c.meet ? "Google Meet" : "No video call") { c.meet.toggle() }
        if model.store.writableCalendars.count > 1 {
            let current = model.store.writableCalendars.first { $0.id == (c.calendarID ?? model.store.primaryCalendarID) }
            Chip(dot: current?.color ?? .systemBlue, text: current?.name ?? "Calendar") {
                PopMenu.show(model.store.writableCalendars.map { cal in
                    .init(cal.name, checked: cal.id == current?.id) { c.calendarID = cal.id }
                })
            }
        }
        if !suggestedPeople.isEmpty {
            Chip(icon: "plus", text: "Add person", outlined: true) {
                PopMenu.show(suggestedPeople.prefix(12).map { p in
                    .init(p.name.map { "\($0)  (\(p.email))" } ?? p.email) {
                        c.removed.remove(p.email.lowercased())
                        c.extraPeople.append(p)
                    }
                })
            }
        }
    }

    private var suggestedPeople: [Person] {
        let have = Set(c.people.map { $0.email.lowercased() })
        return model.store.contacts.filter { !have.contains($0.email.lowercased()) }
    }

    private var timeText: String {
        guard let s = c.start, let e = c.end else { return "\(c.minutes) min" }
        return "\(Fmt.time(s)) – \(Fmt.time(e))"
    }

    private func relativeDay(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        return d.formatted(.dateTime.weekday(.wide))
    }

    @ViewBuilder private var hint: some View {
        let conflicts = c.conflicts
        HStack(spacing: 8) {
            if let name = c.notFound.first {
                Circle().fill(Color.cueOrange).frame(width: 7, height: 7)
                Text("Couldn’t find \(name). Type their email.").foregroundStyle(.secondary)
            } else if c.start == nil {
                Text("Nobody’s free for \(c.minutes) min that day. Try another day.").foregroundStyle(.secondary)
            } else if !conflicts.isEmpty {
                Circle().fill(Color.cueRed).frame(width: 7, height: 7)
                Text(busyText(conflicts)).foregroundStyle(.secondary)
                slots(c.suggestions.prefix(2))
            } else if c.people.count >= 2 {
                Text("Everyone’s free at").foregroundStyle(.secondary)
                slots(c.suggestions.prefix(3))
            } else {
                Circle().fill(Color(nsColor: .systemGreen)).frame(width: 7, height: 7)
                Text(c.people.first.map { "\($0.firstName) is free then" } ?? "You’re free then").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .frame(minHeight: 24)
    }

    private func busyText(_ names: [String]) -> String {
        if names == ["You"] { return "You’re busy then. Try" }
        let others = names.filter { $0 != "You" }
        let who = others.count == 1 ? "\(others[0])’s" : "\(Fmt.people(others)) are"
        return others.count == 1 ? "\(who) busy then. Try" : "\(who) busy then. Try"
    }

    private func slots(_ times: ArraySlice<Date>) -> some View {
        ForEach(Array(times), id: \.self) { t in
            let on = c.start == t
            Button { c.pick(t) } label: {
                Text(Fmt.time(t)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(on ? Color.white : Color.cueBlue)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(on ? Color.cueBlue : Color.clear))
                    .overlay(Capsule().strokeBorder(on ? Color.clear : Color.cueBlue.opacity(0.45), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// One lane per person; busy time hatched in their colour, free-for-everyone tinted green.
struct LanesView: View {
    @ObservedObject var c: ComposeModel
    let mine: [Meeting]
    private let lo: Double = 8, hi: Double = 20
    private let label: CGFloat = 48

    var body: some View {
        let lanes = c.laneIDs
        let laneH: CGFloat = 22, gap: CGFloat = 6
        let height = CGFloat(lanes.count) * (laneH + gap)
        VStack(spacing: 0) {
            GeometryReader { geo in
                let w = geo.size.width - label
                let x = { (d: Date) -> CGFloat in label + CGFloat((d.timeIntervalSince(c.day) / 3600 - lo) / (hi - lo)) * w }
                ZStack(alignment: .topLeading) {
                    ForEach(Array(c.freeRanges(from: lo, to: hi).enumerated()), id: \.offset) { _, r in
                        if lanes.count > 2 {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .systemGreen).opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .systemGreen).opacity(0.5), lineWidth: 1))
                                .frame(width: max(0, x(r.end) - x(r.start)), height: height + 2)
                                .offset(x: x(r.start), y: -4)
                        }
                    }
                    ForEach(Array(lanes.enumerated()), id: \.offset) { i, id in
                        lane(i, id: id, x: x, width: w)
                            .frame(height: laneH)
                            .offset(y: CGFloat(i) * (laneH + gap))
                    }
                    if let s = c.start, let e = c.end {
                        let bad = !c.conflicts.isEmpty
                        let tint = bad ? Color.cueRed : Color.cueBlue
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tint.opacity(bad ? 0.12 : 0.14))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                            .frame(width: max(6, x(e) - x(s) + 4), height: height + 2)
                            .offset(x: x(s) - 2, y: -4)
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    guard tap.location.x > label else { return }
                    let hours = lo + Double((tap.location.x - label) / w) * (hi - lo)
                    let snapped = (hours * 4).rounded(.down) / 4
                    c.pick(c.day.addingTimeInterval(snapped * 3600))
                })
            }
            .frame(height: height)
            GeometryReader { geo in
                let w = geo.size.width - label
                ForEach([9, 12, 15, 18], id: \.self) { h in
                    Text("\(h)").font(.system(size: 10)).foregroundStyle(Color.tertiary).monospacedDigit()
                        .fixedSize()
                        .frame(width: 30)
                        .offset(x: label + CGFloat((Double(h) - lo) / (hi - lo)) * w - 15)
                }
            }
            .frame(height: 14)
        }
    }

    @ViewBuilder
    private func lane(_ i: Int, id: String, x: @escaping (Date) -> CGFloat, width: CGFloat) -> some View {
        let fb = c.busy[id]
        HStack(spacing: 8) {
            Text(i == 0 ? "You" : c.people[i - 1].firstName)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: label - 8, alignment: .leading)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)).frame(height: 16)
                if fb?.unavailable == true {
                    Text("Availability not shared").font(.system(size: 10)).foregroundStyle(Color.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center).frame(height: 16)
                } else if i == 0 && !mine.isEmpty {
                    ForEach(mine, id: \.key) { m in
                        RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: m.color))
                            .frame(width: max(3, x(m.end) - x(m.start) - 1), height: 16)
                            .offset(x: x(m.start) - label)
                    }
                } else {
                    let color = i == 0 ? NSColor.systemBlue : ComposeView.laneColors[(i - 1) % ComposeView.laneColors.count]
                    ForEach(Array((fb?.busy ?? []).enumerated()), id: \.offset) { _, b in
                        let start = max(b.start, c.day.addingTimeInterval(lo * 3600))
                        let end = min(b.end, c.day.addingTimeInterval(hi * 3600))
                        if end > start {
                            Group {
                                if i == 0 {
                                    RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: color))
                                } else {
                                    Hatch(color: Color(nsColor: color))
                                }
                            }
                            .frame(width: max(3, x(end) - x(start) - 1), height: 16)
                            .offset(x: x(start) - label)
                        }
                    }
                }
            }
            .frame(width: width, height: 16, alignment: .topLeading)
            .clipped()
        }
    }
}

struct Hatch: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 6
            }
            ctx.stroke(p, with: .color(color), lineWidth: 2.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: 1))
        .opacity(0.8)
    }
}

// MARK: - Small pieces

struct Chip: View {
    var icon: String? = nil
    var avatar: (String, NSColor)? = nil
    var dot: NSColor? = nil
    let text: String
    var outlined = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary) }
                if let (initials, color) = avatar {
                    Text(initials).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 16, height: 16).background(Circle().fill(Color(nsColor: color)))
                }
                if let dot { Circle().fill(Color(nsColor: dot)).frame(width: 7, height: 7) }
                Text(text).lineLimit(1).monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(outlined ? Color.secondary : Color.primary)
            .padding(.leading, avatar != nil ? 4 : 7)
            .padding(.trailing, 9)
            .frame(height: 24)
            .background(Capsule().fill(outlined ? Color.clear : Color.fill))
            .overlay(Capsule().strokeBorder(outlined ? Color.primary.opacity(0.12) : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// Native menus for chips, so the chips themselves can look however we like.
enum PopMenu {
    struct Item {
        var title: String
        var checked = false
        var action: (() -> Void)?
        var isSeparator = false

        init(_ title: String, checked: Bool = false, action: @escaping () -> Void) {
            self.title = title
            self.checked = checked
            self.action = action
        }

        private init(separator: Void) {
            title = ""
            isSeparator = true
        }

        static let separator = Item(separator: ())
    }

    private final class Target: NSObject {
        let action: () -> Void
        init(_ a: @escaping () -> Void) { action = a }
        @objc func fire() { action() }
    }

    @MainActor static func show(_ items: [Item]) {
        let menu = NSMenu()
        var targets: [Target] = []
        for item in items {
            if item.isSeparator { menu.addItem(.separator()); continue }
            let mi = NSMenuItem(title: item.title, action: #selector(Target.fire), keyEquivalent: "")
            if let a = item.action {
                let t = Target(a)
                targets.append(t)
                mi.target = t
            }
            mi.state = item.checked ? .on : .off
            menu.addItem(mi)
        }
        withExtendedLifetime(targets) {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

/// A single-line text field that tints the words Cue understood.
struct TokenField: NSViewRepresentable {
    @Binding var text: String
    var tokens: [NSRange]
    var placeholder: String
    var fontSize: CGFloat = 15
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: fontSize)
        f.placeholderString = placeholder
        f.allowsEditingTextAttributes = true
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.delegate = context.coordinator
        f.stringValue = text
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        context.coordinator.tint(f)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TokenField
        init(_ p: TokenField) { parent = p }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            if sel == #selector(NSResponder.cancelOperation(_:)) { parent.onCancel(); return true }
            return false
        }

        func tint(_ f: NSTextField) {
            guard let editor = f.currentEditor() as? NSTextView, let storage = editor.textStorage else { return }
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: parent.fontSize), range: all)
            for r in parent.tokens where NSMaxRange(r) <= storage.length {
                storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: r)
            }
            storage.endEditing()
            editor.typingAttributes = [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: parent.fontSize)]
        }
    }
}
