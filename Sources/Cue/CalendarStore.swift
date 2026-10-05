import AppKit
import EventKit

/// Today's and tomorrow's timed meetings, from Google Calendar (polled every few minutes)
/// or macOS Calendar (reloaded only when EventKit reports a change).
@MainActor
final class CalendarStore: ObservableObject {
    enum Access: Equatable { case unknown, granted, denied, needsGoogle }
    enum Source: String { case google, macos }
    enum GoogleState: Equatable { case idle, signingIn, expired, failed(String) }

    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var access: Access = .unknown
    @Published private(set) var source: Source
    @Published private(set) var googleState: GoogleState = .idle
    @Published private(set) var googleCalendars: [GCalendar] = []

    let google = GoogleAuth()
    private let store = EKEventStore()
    private var loadedDay = Date.distantPast
    private var lastFetch = Date.distantPast
    private var fetching = false
    private var demo = false
    private static let pollInterval: TimeInterval = 180

    var googleEmail: String? { google.email }
    var canWrite: Bool { demo || (source == .google && google.canWrite) }
    var canCreate: Bool { demo || (source == .google && google.isSignedIn) }
    var writableCalendars: [GCalendar] { googleCalendars.filter(\.writable) }
    var primaryCalendarID: String { googleCalendars.first { $0.primary == true }?.id ?? google.email ?? "primary" }

    /// People you've had meetings with lately, most frequent first. Used for suggestions.
    @Published private(set) var contacts: [Person] = []
    private var contactsFetched = Date.distantPast
    private var freeBusyCache: [String: (at: Date, value: FreeBusy)] = [:]

    init() {
        let saved = UserDefaults.standard.string(forKey: "source").flatMap(Source.init(rawValue:))
        source = saved ?? (google.client != nil ? .google : .macos)
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.source == .macos { self?.reload() } }
        }
    }

    func start() {
        guard !demo else { return }
        switch source {
        case .macos:
            requestAccess()
        case .google:
            access = google.isSignedIn ? .granted : .needsGoogle
            refresh()
        }
    }

    func setSource(_ s: Source) {
        guard s != source else { return }
        source = s
        UserDefaults.standard.set(s.rawValue, forKey: "source")
        meetings = []
        loadedDay = .distantPast
        lastFetch = .distantPast
        start()
    }

    /// Called every minute. Google is polled every three minutes; EventKit only at day rollover.
    func tick(now: Date) {
        switch source {
        case .google where Date().timeIntervalSince(lastFetch) >= Self.pollInterval: refresh()
        case .macos where !Calendar.current.isDate(now, inSameDayAs: loadedDay): reload()
        default: break
        }
    }

    /// After wake or when the popover opens, so what you see is fresh.
    func refreshIfStale(_ age: TimeInterval = 60) {
        if source == .google, Date().timeIntervalSince(lastFetch) >= age { refresh() } else if source == .macos { reload() }
    }

    func refresh() {
        switch source {
        case .macos: reload()
        case .google: fetchGoogle()
        }
    }

    // MARK: macOS Calendar

    func requestAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
            reload()
        case .notDetermined:
            store.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async {
                    self.access = granted ? .granted : .denied
                    self.reload()
                }
            }
        default:
            access = .denied
        }
    }

    func reload() {
        guard source == .macos, access == .granted, !demo else { return }
        let (today, end) = Self.window()
        let events = store.events(matching: store.predicateForEvents(withStart: today, end: end, calendars: nil))
        let next = events
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.declined($0) }
            .map(Meeting.init(event:))
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        loadedDay = today
        if next != meetings { meetings = next }
    }

    private static func declined(_ e: EKEvent) -> Bool {
        e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    private static func window() -> (Date, Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Clock.now())
        return (today, cal.date(byAdding: .day, value: 2, to: today) ?? today.addingTimeInterval(2 * 86400))
    }

    // MARK: Google Calendar

    func signInWithGoogle() {
        googleState = .signingIn
        Task {
            do {
                try await google.signIn()
                googleState = .idle
                access = .granted
                lastFetch = .distantPast
                fetchGoogle()
            } catch GoogleError.cancelled {
                googleState = .idle
            } catch {
                googleState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelGoogleSignIn() { google.cancelSignIn() }

    func signOutOfGoogle() {
        google.signOut()
        meetings = []
        googleCalendars = []
        access = .needsGoogle
        objectWillChange.send()
    }

    /// Calendars ticked in Google Calendar's own sidebar show by default; Settings can override.
    func isShown(_ c: GCalendar) -> Bool {
        let overrides = UserDefaults.standard.dictionary(forKey: "shownCalendars") as? [String: Bool] ?? [:]
        return overrides[c.id] ?? (c.selected == true && c.hidden != true)
    }

    func setShown(_ c: GCalendar, _ on: Bool) {
        var overrides = UserDefaults.standard.dictionary(forKey: "shownCalendars") as? [String: Bool] ?? [:]
        overrides[c.id] = on
        UserDefaults.standard.set(overrides, forKey: "shownCalendars")
        lastFetch = .distantPast
        fetchGoogle()
    }

    private func fetchGoogle() {
        guard source == .google, google.isSignedIn, !fetching, !demo else { return }
        fetching = true
        Task {
            defer { fetching = false }
            do {
                let token = try await google.validToken()
                let calendars = try await GoogleCalendarAPI.calendars(token: token)
                // Primary first, so an event on several calendars keeps your own calendar's colour.
                let chosen = calendars.filter(isShown).sorted { ($0.primary == true ? 0 : 1) < ($1.primary == true ? 0 : 1) }
                let (from, to) = Self.window()
                let results = try await withThrowingTaskGroup(of: (Int, [GEvent]).self) { group in
                    for (i, c) in chosen.enumerated() {
                        group.addTask { (i, try await GoogleCalendarAPI.events(calendarID: c.id, from: from, to: to, token: token)) }
                    }
                    var out: [(Int, [GEvent])] = []
                    for try await r in group { out.append(r) }
                    return out.sorted { $0.0 < $1.0 }
                }
                var seen = Set<String>()
                var next: [Meeting] = []
                for (i, events) in results {
                    for e in events {
                        guard let m = Meeting(google: e, calendar: chosen[i]) else { continue }
                        if seen.insert("\(e.iCalUID ?? e.id)|\(m.start.timeIntervalSince1970)").inserted { next.append(m) }
                    }
                }
                next.sort { ($0.start, $0.end) < ($1.start, $1.end) }
                lastFetch = Date()
                loadedDay = from
                if calendars != googleCalendars { googleCalendars = calendars }
                if next != meetings { meetings = next }
                if access != .granted { access = .granted }
                if Date().timeIntervalSince(contactsFetched) > 12 * 3600 { fetchContacts(token: token) }
                if googleState != .idle { googleState = .idle }
            } catch GoogleError.expired {
                googleState = .expired
                access = .needsGoogle
            } catch {
                // Offline or a hiccup: keep what we have and try again in a minute.
                lastFetch = Date().addingTimeInterval(-Self.pollInterval + 60)
            }
        }
    }

    // MARK: Google writes

    private func write(_ op: @escaping (String) async throws -> Void) async throws {
        guard canWrite else { throw GoogleError.needsWriteAccess }
        if demo { return }
        let token = try await google.validToken()
        do {
            try await op(token)
        } catch GoogleError.needsWriteAccess {
            throw GoogleError.needsWriteAccess
        }
        lastFetch = .distantPast
        fetchGoogle()
    }

    func create(_ draft: GoogleCalendarAPI.Draft, calendarID: String?) async throws {
        try await write { try await GoogleCalendarAPI.insert(draft, calendarID: calendarID ?? self.primaryCalendarID, token: $0) }
    }

    func update(_ m: Meeting, changes: [String: Any]) async throws {
        guard let cal = m.calendarID, !changes.isEmpty else { return }
        try await write { try await GoogleCalendarAPI.patch(calendarID: cal, eventID: m.id, changes: changes, token: $0) }
    }

    func delete(_ m: Meeting) async throws {
        guard let cal = m.calendarID else { return }
        meetings.removeAll { $0.key == m.key }
        try await write { try await GoogleCalendarAPI.delete(calendarID: cal, eventID: m.id, token: $0) }
    }

    /// Changes only your own reply; everyone else's stays as it was.
    func rsvp(_ m: Meeting, _ status: String) async throws {
        guard let cal = m.calendarID, m.people.contains(where: \.isSelf) else { return }
        let people = m.people.map { p -> Person in var p = p; if p.isSelf { p.status = status }; return p }
        if let i = meetings.firstIndex(where: { $0.key == m.key }) {
            meetings[i].people = people
            meetings[i].selfStatus = status
        }
        try await write {
            try await GoogleCalendarAPI.patch(calendarID: cal, eventID: m.id,
                                              changes: ["attendees": GoogleCalendarAPI.attendeesBody(people)], token: $0)
        }
    }

    /// Busy blocks for a day, cached for five minutes so typing doesn't hammer Google.
    func freeBusy(_ ids: [String], day: Date) async -> [String: FreeBusy] {
        let cal = Calendar.current
        let from = cal.startOfDay(for: day)
        let to = cal.date(byAdding: .day, value: 1, to: from) ?? from.addingTimeInterval(86400)
        let keys = ids.map { $0.lowercased() }
        func cacheKey(_ id: String) -> String { "\(id)|\(from.timeIntervalSince1970)" }
        var out: [String: FreeBusy] = [:]
        var missing: [String] = []
        for id in keys {
            if let hit = freeBusyCache[cacheKey(id)], Date().timeIntervalSince(hit.at) < 300 { out[id] = hit.value } else { missing.append(id) }
        }
        if demo {
            for id in missing { out[id] = Self.demoBusy(id, day: from) }
            return out
        }
        guard !missing.isEmpty, let token = try? await google.validToken(),
              let fetched = try? await GoogleCalendarAPI.freeBusy(ids: missing, from: from, to: to, token: token) else { return out }
        for (id, fb) in fetched {
            freeBusyCache[cacheKey(id)] = (Date(), fb)
            out[id] = fb
        }
        return out
    }

    private func fetchContacts(token: String) {
        contactsFetched = Date()
        let now = Date()
        Task {
            guard let events = try? await GoogleCalendarAPI.events(
                calendarID: primaryCalendarID, from: now.addingTimeInterval(-60 * 86400), to: now.addingTimeInterval(14 * 86400),
                token: token, fields: "attendees(email,displayName,self,resource)") else { return }
            var counts: [String: (Person, Int)] = [:]
            for e in events {
                for a in e.attendees ?? [] where a.isSelf != true && a.resource != true {
                    guard let email = a.email?.lowercased(), !email.contains("calendar.google.com") else { continue }
                    let p = Person(email: email, name: a.displayName ?? counts[email]?.0.name)
                    counts[email] = (p, (counts[email]?.1 ?? 0) + 1)
                }
            }
            contacts = counts.values.sorted { $0.1 > $1.1 }.map(\.0)
        }
    }

    // MARK: Demo data (matches the mockups)

    private static func demoBusy(_ id: String, day: Date) -> FreeBusy {
        let cal = Calendar.current
        func iv(_ a: (Int, Int), _ b: (Int, Int)) -> DateInterval {
            DateInterval(start: cal.date(byAdding: DateComponents(hour: a.0, minute: a.1), to: day)!,
                         end: cal.date(byAdding: DateComponents(hour: b.0, minute: b.1), to: day)!)
        }
        if id.hasPrefix("priya") { return FreeBusy(busy: [iv((9, 30), (10, 45)), iv((15, 0), (16, 0)), iv((17, 0), (18, 0))], unavailable: false) }
        if id.hasPrefix("rahul") { return FreeBusy(busy: [iv((10, 30), (10, 45)), iv((11, 0), (12, 0)), iv((13, 30), (14, 0)), iv((16, 30), (17, 30))], unavailable: false) }
        return FreeBusy(busy: [iv((10, 30), (10, 45)), iv((15, 0), (16, 0))], unavailable: false)
    }

    func loadDemo() {
        demo = true
        source = .google
        contacts = ["Priya Shah", "Rahul Kumar", "Aman Mehta", "Neha Joshi", "Vikram Tiwari"].map {
            Person(email: $0.lowercased().replacingOccurrences(of: " ", with: ".") + "@browserstack.com", name: $0)
        }
        access = .granted
        let cal = Calendar.current
        let today = cal.startOfDay(for: Clock.now())
        func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
            cal.date(byAdding: DateComponents(day: day, hour: h, minute: m), to: today)!
        }
        let meet = MeetingLink(url: URL(string: "https://meet.google.com/abc-defg-hij")!, service: "Google Meet")
        let zoom = MeetingLink(url: URL(string: "https://zoom.us/j/1234567890")!, service: "Zoom")
        let team = ["Rahul Kumar", "Priya Shah", "Aman Mehta", "Neha Joshi", "Vikram Tiwari", "Sara Lee"]
        func m(_ t: String, _ d: Int, _ sh: Int, _ sm: Int, _ eh: Int, _ em: Int, _ c: NSColor, _ cal: String, _ l: MeetingLink?, _ p: [String] = []) -> Meeting {
            var x = Meeting(id: t, title: t, start: at(d, sh, sm), end: at(d, eh, em), color: c, calendarName: cal, link: l, attendees: p)
            x.calendarID = "demo"
            x.people = p.enumerated().map { i, n in
                Person(email: n.lowercased().replacingOccurrences(of: " ", with: ".") + "@browserstack.com", name: n,
                       status: "accepted", organizer: i == 0)
            } + [Person(email: "you@browserstack.com", name: nil, status: "accepted", isSelf: true)]
            x.selfStatus = "accepted"
            x.canModify = true
            return x
        }
        meetings = [
            m("Inbox and PR reviews", 0, 9, 0, 9, 30, .systemGreen, "Focus", nil),
            m("MOBPC ticket grooming", 0, 9, 45, 10, 15, .systemTeal, "Ops", meet, team),
            { var x = m("Mobile platform standup", 0, 10, 30, 10, 45, .systemBlue, "Work", meet, team); x.room = "BLR 3F Everest"; return x }(),
            m("AI Harness sync", 0, 11, 0, 11, 45, .systemPurple, "AI Harness", zoom, team),
            m("Lunch", 0, 13, 0, 14, 0, .systemOrange, "Personal", nil),
            { var x = m("1:1 with Rahul", 0, 14, 30, 15, 0, .systemBlue, "Work", meet, ["Rahul Kumar"]); x.notes = "Agenda: Q4 goals, Private Cloud on-call rotation, and the MOBPC triage backlog."; return x }(),
            m("Private Cloud design review", 0, 16, 0, 17, 0, .systemBlue, "Work", meet, team),
            m("Mobile platform standup", 1, 10, 30, 10, 45, .systemBlue, "Work", meet, team),
            m("Pulse dashboard demo", 1, 15, 0, 16, 0, .systemPurple, "AI Harness", meet, team),
        ]
    }
}

/// Wall clock with an optional offset, so demo mode can pretend it's 10:18.
enum Clock {
    static var offset: TimeInterval = 0
    static func now() -> Date { Date().addingTimeInterval(offset) }

    static func setDemo(time: String) {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = parts[0]
        c.minute = parts[1]
        c.second = parts.count > 2 ? parts[2] : 0
        if let d = Calendar.current.date(from: c) { offset = d.timeIntervalSinceNow }
    }
}
