import AppKit
import EventKit
import SwiftUI

struct MeetingLink: Equatable {
    let url: URL
    let service: String
    /// What you'd type to join by hand: meeting ID and passcode, or the Meet code.
    var codes: [CallCode] = []

    var kind: CallKind { CallKind(service: service) }

    /// This link with its codes filled in from the invite text.
    func reading(_ texts: [String?], known: CallCodes.Known = .init()) -> MeetingLink {
        var out = self
        out.codes = CallCodes.read(self, texts: texts, known: known)
        return out
    }
}

struct CallCode: Equatable, Hashable {
    let label: String
    let value: String
}

/// The call apps Cue knows by sight. Each has its own colour and camera mark for the Join button.
enum CallKind {
    case zoom, meet, teams, webex, slack, other

    init(service: String) {
        let s = service.lowercased()
        if s.contains("zoom") { self = .zoom }
        else if s.contains("meet") && s.contains("google") || s == "google meet" { self = .meet }
        else if s.contains("teams") { self = .teams }
        else if s.contains("webex") { self = .webex }
        else if s.contains("slack") { self = .slack }
        else { self = .other }
    }

    /// The brand colour, a shade brighter in dark mode. Anything unknown stays Cue blue.
    var nsColor: NSColor {
        let pair: (UInt32, UInt32)
        switch self {
        case .zoom: pair = (0x0B5CFF, 0x2F74FF)
        case .meet: pair = (0x00832D, 0x1A9A4A)
        case .teams: pair = (0x5B5FC7, 0x7579EB)
        case .webex: pair = (0x0A6FD1, 0x2B8AF0)
        case .slack: pair = (0x007A5A, 0x1F9D74)
        case .other: return .systemBlue
        }
        func c(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        let light = c(pair.0), dark = c(pair.1)
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// SF Symbol for kinds without a drawn mark.
    var symbol: String? {
        switch self {
        case .slack: return "headphones"
        case .other: return "video.fill"
        default: return nil
        }
    }

    /// The app's camera mark on a 24-point grid, filled even-odd. Nil when `symbol` is used instead.
    var glyph: Path? {
        func lens(_ x0: CGFloat, _ inner: CGFloat, _ x1: CGFloat, _ outer: CGFloat, _ r: CGFloat) -> Path {
            let pts = [CGPoint(x: x0, y: 12 - inner), CGPoint(x: x1, y: 12 - outer), CGPoint(x: x1, y: 12 + outer), CGPoint(x: x0, y: 12 + inner)]
            var p = Path()
            p.move(to: CGPoint(x: x0, y: 12))
            for i in 0..<4 {
                p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % 4], radius: i == 0 || i == 3 ? 0.3 : r)
            }
            p.closeSubpath()
            return p
        }
        func body(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
            Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
        }
        var p = Path()
        switch self {
        case .zoom:
            p.addPath(body(1, 5.5, 14.5, 13, 3.6))
            p.addPath(lens(17, 1.4, 23, 5.4, 1.2))
        case .meet:
            p.addPath(body(1.5, 4.5, 15, 15, 4))
            p.addEllipse(in: CGRect(x: 3.9, y: 13.6, width: 4, height: 4))
            p.addPath(lens(17.6, 2.6, 23, 6, 1.5))
        case .teams:
            p.addPath(body(2, 4.5, 15, 15, 3.25))
            p.addPath(lens(16.5, 4.1, 22, 7, 0.9))
        case .webex:
            p.addPath(body(1.5, 5, 14, 14, 2.5))
            p.addPath(lens(17, 2.2, 23, 6, 1.2))
        case .slack, .other:
            return nil
        }
        return p
    }
}

/// The call's mark at a given size, in the current foreground colour.
struct CallIcon: View {
    let kind: CallKind
    var size: CGFloat = 14

    var body: some View {
        if let glyph = kind.glyph {
            glyph.fill(style: FillStyle(eoFill: true))
                .frame(width: 24, height: 24)
                .scaleEffect(size / 24)
                .frame(width: size, height: size)
        } else {
            Image(systemName: kind.symbol ?? "video.fill")
                .font(.system(size: size * 0.8, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}

/// Someone invited to a meeting, or a suggestion for one.
struct Person: Equatable, Hashable {
    var email: String
    var name: String?
    var status: String? = nil   // accepted, tentative, declined, needsAction
    var isSelf = false
    var organizer = false
    var optional = false
    var resource = false

    var display: String { name ?? email }
    var firstName: String { Fmt.firstName(display) }
}

struct Meeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: NSColor
    let calendarName: String
    let link: MeetingLink?
    let attendees: [String]
    /// Google Calendar's page for the event, when it came from Google.
    var webURL: URL? = nil
    /// Booked room or physical location, shown next to the call link.
    var room: String? = nil
    /// Google only: which calendar holds it, who's invited, and what you can change.
    var calendarID: String? = nil
    var people: [Person] = []
    var notes: String? = nil
    var selfStatus: String? = nil
    var isOrganizer = false
    var canModify = false

    /// Recurring events share an identifier, so the start time is part of the key.
    var key: String { "\(id)|\(start.timeIntervalSince1970)" }

    /// Fits the menu bar: whole words up to ~18 characters, then an ellipsis.
    var shortTitle: String {
        guard title.count > 18 else { return title }
        var out = ""
        for word in title.split(separator: " ") {
            let next = out.isEmpty ? String(word) : out + " " + word
            if next.count > 17 { break }
            out = next
        }
        return (out.isEmpty ? String(title.prefix(17)) : out) + "…"
    }

    func isLive(at now: Date) -> Bool { start <= now && now < end }

    static func == (a: Meeting, b: Meeting) -> Bool {
        a.key == b.key && a.title == b.title && a.end == b.end && a.link == b.link
            && a.attendees == b.attendees && a.calendarName == b.calendarName && a.room == b.room
            && a.people == b.people && a.notes == b.notes && a.selfStatus == b.selfStatus
    }
}

extension Meeting {
    init(event: EKEvent) {
        id = event.calendarItemIdentifier
        title = (event.title?.isEmpty == false ? event.title : nil) ?? "Untitled"
        start = event.startDate
        end = event.endDate
        color = event.calendar.flatMap { NSColor(cgColor: $0.cgColor) } ?? .systemBlue
        calendarName = event.calendar?.title ?? ""
        link = LinkDetector.detect([event.url?.absoluteString, event.location, event.notes])?.reading([event.location, event.notes])
        room = Meeting.place(event.location)
        attendees = (event.attendees ?? [])
            .filter { !$0.isCurrentUser && $0.participantType == .person }
            .map { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
    }
}

extension Meeting {
    /// Google descriptions are HTML; show them as plain text.
    static func plainText(fromHTML html: String?) -> String? {
        guard var s = html, !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// A location worth showing: not empty, not a link, not a "join on Teams" placeholder.
    static func place(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              !t.contains("://"), !t.lowercased().contains("zoom.us"),
              t.lowercased() != "microsoft teams meeting", t.lowercased() != "google meet" else { return nil }
        return t
    }
}

enum LinkDetector {
    private static let rules: [(service: String, regex: NSRegularExpression)] = [
        ("Google Meet", #"https?://meet\.google\.com/[a-z]{3,}-[a-z]{3,}-[a-z]{3,}[^\s<>"']*"#),
        ("Zoom", #"https?://(?:[\w-]+\.)?zoom\.us/(?:j|my|w|s)/[^\s<>"']+"#),
        ("Zoom", #"zoommtg://[^\s<>"']+"#),
        ("Microsoft Teams", #"https?://teams\.microsoft\.com/l/meetup-join/[^\s<>"']+"#),
        ("Microsoft Teams", #"https?://teams\.live\.com/meet/[^\s<>"']+"#),
        ("Webex", #"https?://(?:[\w-]+\.)?webex\.com/(?:meet|join|[\w-]+/j\.php)[^\s<>"']*"#),
        ("Amazon Chime", #"https?://chime\.aws/\d+"#),
        ("Whereby", #"https?://whereby\.com/[^\s<>"']+"#),
        ("Jitsi", #"https?://meet\.jit\.si/[^\s<>"']+"#),
        ("Slack huddle", #"https?://app\.slack\.com/huddle/[^\s<>"']+"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: .caseInsensitive)) }

    /// Checks each text in order (event URL, location, notes) and returns the first call link.
    static func detect(_ texts: [String?]) -> MeetingLink? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for rule in rules {
                guard let match = rule.regex.firstMatch(in: text, range: range),
                      let r = Range(match.range, in: text) else { continue }
                var s = String(text[r])
                while let last = s.last, ").,;]".contains(last) { s.removeLast() }
                if let url = URL(string: s) { return MeetingLink(url: url, service: rule.service) }
            }
        }
        return nil
    }
}

/// Pulls the meeting ID, passcode or Meet code out of a call link and its invite text.
enum CallCodes {
    /// Codes Google already split out of the invite (`conferenceData.entryPoints`).
    struct Known {
        var meetingCode: String?
        var passcode: String?
    }

    static func read(_ link: MeetingLink, texts: [String?], known: Known = Known()) -> [CallCode] {
        let text = texts.compactMap { $0 }.joined(separator: "\n")
        let kind = link.kind
        switch kind {
        case .meet:
            let code = known.meetingCode ?? link.url.pathComponents.last { $0.range(of: #"^[a-z]{3,}-[a-z]{3,}-[a-z]{3,}$"#, options: .regularExpression) != nil }
            return code.map { [CallCode(label: "Code", value: $0)] } ?? []
        case .zoom, .teams, .webex:
            var id = known.meetingCode ?? (kind == .zoom ? zoomID(link.url) : nil)
                ?? match(text, #"(?:meeting id|meeting number|access code)\s*[:：]?\s*(\d[\d ]{6,}\d)"#)
            id = id.map { kind == .zoom ? spaced($0) : $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
            let pass = known.passcode ?? match(text, #"(?:pass ?code|meeting password|password)\s*[:：]\s*([^\s<>()]+)"#)
            var out: [CallCode] = []
            if let id { out.append(CallCode(label: kind == .webex ? "Meeting number" : "Meeting ID", value: id)) }
            if let pass { out.append(CallCode(label: kind == .webex ? "Password" : "Passcode", value: pass)) }
            return out
        case .slack, .other:
            return []
        }
    }

    /// zoom.us/j/84329156720 and zoommtg://…?confno=84329156720 both carry the ID.
    private static func zoomID(_ url: URL) -> String? {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let n = comps?.queryItems?.first(where: { $0.name == "confno" })?.value { return n }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, ["j", "w", "s"].contains(parts[0]), parts[1].allSatisfy(\.isNumber) else { return nil }
        return parts[1]
    }

    /// Zoom writes IDs as 123 456 7890 or 123 4567 8901.
    private static func spaced(_ id: String) -> String {
        let d = id.filter(\.isNumber)
        let groups: [Int]
        switch d.count {
        case 9: groups = [3, 3, 3]
        case 10: groups = [3, 3, 4]
        case 11: groups = [3, 4, 4]
        default: return id
        }
        var out: [String] = [], i = d.startIndex
        for g in groups {
            let j = d.index(i, offsetBy: g)
            out.append(String(d[i..<j]))
            i = j
        }
        return out.joined(separator: " ")
    }

    private static func match(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
    }
}

enum Joiner {
    /// Demo mode never opens real links.
    static var dryRun = false

    static func open(_ link: MeetingLink) {
        var url = link.url
        if link.service == "Zoom", let native = zoomNative(url),
           NSWorkspace.shared.urlForApplication(toOpen: native) != nil {
            url = native
        }
        if !dryRun { NSWorkspace.shared.open(url) }
    }

    /// zoom.us/j/123?pwd=x → zoommtg://zoom.us/join?confno=123&pwd=x, skipping the browser hop.
    private static func zoomNative(_ url: URL) -> URL? {
        guard url.scheme?.hasPrefix("http") == true,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = comps.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "j" || parts[0] == "w" else { return nil }
        var out = URLComponents()
        out.scheme = "zoommtg"
        out.host = comps.host ?? "zoom.us"
        out.path = "/join"
        var query = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(parts[1]))]
        if let pwd = comps.queryItems?.first(where: { $0.name == "pwd" })?.value {
            query.append(URLQueryItem(name: "pwd", value: pwd))
        }
        out.queryItems = query
        return out.url
    }

    static func openInCalendar(_ m: Meeting) {
        if let web = m.webURL {
            NSWorkspace.shared.open(web)
            return
        }
        let encoded = m.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? m.id
        if let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openCalendarApp(google: Bool) {
        if google {
            NSWorkspace.shared.open(URL(string: "https://calendar.google.com/calendar/r/day")!)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        }
    }
}
