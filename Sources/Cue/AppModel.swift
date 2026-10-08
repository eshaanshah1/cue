import AppKit
import Combine

/// Owns the clock tick and the alert flow: overlay → minimized card → closed. Joining closes it.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case shown, minimized, joined, dismissed, snoozed(Date) }

    enum BarState: Equatable {
        case idle
        case later(Meeting)
        case soon(Meeting, minutes: Int)
        case join(Meeting)
        case during(Meeting, minutesLeft: Int, elapsed: Double)
    }

    @Published private(set) var now = Clock.now()
    /// The meeting the overlay or card is about.
    @Published private(set) var active: Meeting?

    /// Which screen the popover shows.
    enum Route: Equatable { case main, compose, detail(String), edit(String), permission }
    @Published var route: Route = .main
    /// The draft survives the popover closing, until it's created or cancelled.
    @Published private(set) var compose: ComposeModel?

    let store: CalendarStore
    lazy var overlay = OverlayController(model: self)
    lazy var card = MiniCardController(model: self)

    private var phases: [String: Phase] = [:]
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    var meetings: [Meeting] { store.meetings }
    var alertsEnabled: Bool { UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true }

    init(store: CalendarStore) {
        self.store = store
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        store.$meetings.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.tick() }.store(in: &bag)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.refreshIfStale(0)
                self?.tick()
            }
        }
    }

    func start() { tick() }

    // MARK: Popover navigation

    func newEvent() {
        guard store.canCreate else { return }
        guard store.canWrite else { route = .permission; return }
        if compose == nil { compose = ComposeModel(store: store) }
        route = .compose
    }

    func finishCompose() {
        compose = nil
        route = .main
    }

    func cancelCompose() {
        compose = nil
        route = .main
    }

    func meeting(_ key: String) -> Meeting? { meetings.first { $0.key == key } }

    func open(_ m: Meeting) { route = .detail(m.key) }

    func edit(_ m: Meeting) {
        guard store.canWrite else { route = .permission; return }
        route = .edit(m.key)
    }

    /// Esc steps back one screen before it closes the popover.
    func back() -> Bool {
        switch route {
        case .main: return false
        case .edit(let k): route = .detail(k)
        case .compose: route = .main
        default: route = .main
        }
        return true
    }

    /// Snapshot mode: move the clock without running alerts.
    func freeze() { now = Clock.now() }

    // MARK: Clock

    func tick() {
        now = Clock.now()
        store.tick(now: now)
        evaluateAlerts()
        scheduleNextTick()
    }

    /// One timer, aimed at the next minute boundary (or a sooner snooze). Nothing else polls.
    private func scheduleNextTick() {
        timer?.invalidate()
        let t = now.timeIntervalSinceReferenceDate
        var next = (floor(t / 60) + 1) * 60
        for case let .snoozed(until) in phases.values where until.timeIntervalSinceReferenceDate > t {
            next = min(next, until.timeIntervalSinceReferenceDate)
        }
        let timer = Timer(timeInterval: max(0.05, next - t), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Menu bar

    var barState: BarState {
        let cal = Calendar.current
        if let m = meetings.first(where: { m in
            m.link != nil && now >= m.start.addingTimeInterval(-60) && now < m.start.addingTimeInterval(5 * 60)
                && phases[m.key] != .joined && phases[m.key] != .dismissed
        }) {
            return .join(m)
        }
        if let m = meetings.filter({ $0.isLive(at: now) }).max(by: { $0.start < $1.start }) {
            let elapsed = now.timeIntervalSince(m.start) / m.end.timeIntervalSince(m.start)
            return .during(m, minutesLeft: Fmt.minutes(m.end.timeIntervalSince(now)), elapsed: (elapsed * 50).rounded() / 50)
        }
        if let n = meetings.first(where: { $0.start > now }), cal.isDate(n.start, inSameDayAs: now) {
            let mins = Fmt.minutes(n.start.timeIntervalSince(now))
            return mins <= 60 ? .soon(n, minutes: mins) : .later(n)
        }
        return .idle
    }

    // MARK: Popover content

    /// What the top of the popover is about: a meeting starting soon wins over one in progress.
    var hero: Meeting? {
        let live = meetings.filter { $0.isLive(at: now) }.max { $0.start < $1.start }
        let upcoming = meetings.first { $0.start > now }
        if let u = upcoming, live == nil || u.start.timeIntervalSince(now) <= 15 * 60 { return u }
        return live
    }

    var laterToday: [Meeting] {
        meetings.filter { $0.start > now && Calendar.current.isDate($0.start, inSameDayAs: now) && $0.key != hero?.key }
    }

    var tomorrow: [Meeting] {
        meetings.filter { !Calendar.current.isDate($0.start, inSameDayAs: now) && $0.key != hero?.key }
    }

    var today: [Meeting] { meetings.filter { Calendar.current.isDate($0.start, inSameDayAs: now) } }

    // MARK: Alerts

    private func evaluateAlerts() {
        if let a = active {
            if now >= a.end { closeActive(); return }
            if let fresh = meetings.first(where: { $0.key == a.key }), fresh != a { active = fresh }
        }
        guard alertsEnabled else { return }
        for m in meetings where m.link != nil && m.key != active?.key {
            switch phases[m.key] {
            case nil where now >= m.start.addingTimeInterval(-60) && now < m.start.addingTimeInterval(5 * 60):
                present(m)
                return
            case .snoozed(let until)? where now >= until && now < m.end:
                present(m)
                return
            default:
                continue
            }
        }
    }

    func present(_ m: Meeting) {
        if let a = active, a.key != m.key { phases[a.key] = .dismissed }
        active = m
        phases[m.key] = .shown
        card.hide()
        overlay.show(m)
    }

    func minimize() {
        guard let m = active, overlay.isVisible else { return }
        phases[m.key] = .minimized
        overlay.hide()
        card.show()
    }

    /// Opens the full overlay again from the card.
    func expand() {
        guard let m = active else { return }
        phases[m.key] = .shown
        card.hide()
        overlay.show(m)
    }

    func dismiss() {
        if let m = active { phases[m.key] = .dismissed }
        closeActive()
    }

    func snooze() {
        guard let m = active else { return }
        phases[m.key] = .snoozed(Clock.now().addingTimeInterval(60))
        overlay.hide()
        card.hide()
        active = nil
        scheduleNextTick()
    }

    /// Opens the call and closes whatever alert is up; nothing follows you into the call.
    func join(_ m: Meeting) {
        guard let link = m.link else { Joiner.openInCalendar(m); return }
        Joiner.open(link)
        phases[m.key] = .joined
        if let a = active, a.key != m.key { phases[a.key] = .dismissed }
        closeActive()
        objectWillChange.send()
    }

    private func closeActive() {
        overlay.hide()
        card.hide()
        active = nil
    }
}

enum Fmt {
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    static func range(_ m: Meeting) -> String { "\(time(m.start)) – \(time(m.end))" }
    static func minutes(_ s: TimeInterval) -> Int { max(0, Int((s / 60).rounded(.up))) }

    static func countdown(_ s: TimeInterval) -> String {
        let t = max(0, Int(s.rounded(.up)))
        return "\(t / 60):" + String(format: "%02d", t % 60)
    }

    static func relative(_ m: Meeting, now: Date) -> String {
        let d = m.start.timeIntervalSince(now)
        if d <= 0 { return "Now, \(minutes(m.end.timeIntervalSince(now))) min left" }
        if !Calendar.current.isDate(m.start, inSameDayAs: now) { return "Tomorrow at \(time(m.start))" }
        let mins = minutes(d)
        if mins < 60 { return mins == 1 ? "In 1 minute" : "In \(mins) minutes" }
        let h = mins / 60, r = mins % 60
        return r == 0 ? "In \(h) hr" : "In \(h) hr \(r) min"
    }

    static func firstName(_ s: String) -> String {
        let base = s.contains("@") ? String(s.split(separator: "@")[0]).replacingOccurrences(of: ".", with: " ") : s
        return base.split(separator: " ").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? s
    }

    static func initials(_ s: String) -> String {
        let base = s.contains("@") ? String(s.split(separator: "@")[0]).replacingOccurrences(of: ".", with: " ") : s
        return base.split(separator: " ").prefix(2).compactMap { $0.first }.map { String($0).uppercased() }.joined()
    }

    static func people(_ names: [String]) -> String {
        let first = names.map(firstName)
        switch first.count {
        case 0: return ""
        case 1: return first[0]
        case 2: return "\(first[0]) and \(first[1])"
        case 3: return "\(first[0]), \(first[1]) and 1 other"
        default: return "\(first[0]), \(first[1]) and \(first.count - 2) others"
        }
    }
}
