import AppKit
import EventKit

struct MeetingLink: Equatable {
    let url: URL
    let service: String
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
        link = LinkDetector.detect([event.url?.absoluteString, event.location, event.notes])
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
