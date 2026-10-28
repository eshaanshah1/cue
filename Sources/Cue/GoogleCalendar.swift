import AppKit
import Foundation

struct GCalendar: Decodable, Identifiable, Equatable {
    let id: String
    let summary: String?
    let summaryOverride: String?
    let backgroundColor: String?
    let selected: Bool?
    let primary: Bool?
    let hidden: Bool?
    let accessRole: String?

    var name: String { summaryOverride ?? summary ?? id }
    var color: NSColor { NSColor(hex: backgroundColor) ?? .systemBlue }
    var writable: Bool { accessRole == "owner" || accessRole == "writer" }
}

struct GEvent: Decodable {
    struct Time: Decodable { let dateTime: String? }
    struct Conference: Decodable {
        struct Entry: Decodable {
            let entryPointType: String?
            let uri: String?
            let meetingCode: String?
            let passcode: String?
            let password: String?
        }
        struct Solution: Decodable { let name: String? }
        let conferenceId: String?
        let entryPoints: [Entry]?
        let conferenceSolution: Solution?
    }
    struct Attendee: Decodable {
        let email: String?
        let displayName: String?
        let isSelf: Bool?
        let responseStatus: String?
        let resource: Bool?
        let optional: Bool?
        let organizer: Bool?
        enum CodingKeys: String, CodingKey { case email, displayName, isSelf = "self", responseStatus, resource, optional, organizer }
    }
    struct Organizer: Decodable {
        let isSelf: Bool?
        enum CodingKeys: String, CodingKey { case isSelf = "self" }
    }

    let id: String
    let iCalUID: String?
    let summary: String?
    let status: String?
    let eventType: String?
    let start: Time?
    let end: Time?
    let hangoutLink: String?
    let location: String?
    let description: String?
    let htmlLink: String?
    let conferenceData: Conference?
    let attendees: [GEvent.Attendee]?
    let organizer: Organizer?
    let guestsCanModify: Bool?
}

struct FreeBusy: Equatable {
    var busy: [DateInterval]
    /// Google couldn't share this person's availability (outside the org, or not allowed).
    var unavailable: Bool
}

/// Google Calendar REST. Responses are trimmed with `fields` so each poll is a few KB.
enum GoogleCalendarAPI {
    private static let base = "https://www.googleapis.com/calendar/v3"
    private static let eventFields = "id,iCalUID,summary,status,eventType,start(dateTime),end(dateTime),hangoutLink,location,description,htmlLink,conferenceData(conferenceId,entryPoints(entryPointType,uri,meetingCode,passcode,password),conferenceSolution(name)),attendees(email,displayName,self,responseStatus,resource,optional,organizer),organizer(self),guestsCanModify"
    private static let iso = ISO8601DateFormatter()

    static func calendars(token: String) async throws -> [GCalendar] {
        struct Page: Decodable { let items: [GCalendar]?; let nextPageToken: String? }
        var out: [GCalendar] = []
        var pageToken: String?
        repeat {
            var c = URLComponents(string: "\(base)/users/me/calendarList")!
            c.queryItems = [
                .init(name: "maxResults", value: "250"),
                .init(name: "fields", value: "items(id,summary,summaryOverride,backgroundColor,selected,primary,hidden,accessRole),nextPageToken"),
            ] + (pageToken.map { [.init(name: "pageToken", value: $0)] } ?? [])
            let page: Page = try decode(try await send("GET", c.url!, token: token))
            out += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return out
    }

    static func events(calendarID: String, from: Date, to: Date, token: String, fields: String? = nil) async throws -> [GEvent] {
        struct Page: Decodable { let items: [GEvent]?; let nextPageToken: String? }
        var out: [GEvent] = []
        var pageToken: String?
        repeat {
            var c = URLComponents(string: "\(base)/calendars/\(escape(calendarID))/events")!
            c.queryItems = [
                .init(name: "timeMin", value: iso.string(from: from)),
                .init(name: "timeMax", value: iso.string(from: to)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "maxResults", value: "250"),
                .init(name: "fields", value: "items(\(fields ?? eventFields)),nextPageToken"),
            ] + (pageToken.map { [.init(name: "pageToken", value: $0)] } ?? [])
            let page: Page = try decode(try await send("GET", c.url!, token: token))
            out += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return out
    }

    /// Busy blocks for each calendar or email. Works for anyone whose org shares availability.
    static func freeBusy(ids: [String], from: Date, to: Date, token: String) async throws -> [String: FreeBusy] {
        struct Response: Decodable {
            struct Cal: Decodable {
                struct Block: Decodable { let start: String; let end: String }
                struct Err: Decodable { let reason: String? }
                let busy: [Block]?
                let errors: [Err]?
            }
            let calendars: [String: Cal]?
        }
        let body: [String: Any] = [
            "timeMin": iso.string(from: from),
            "timeMax": iso.string(from: to),
            "items": ids.map { ["id": $0] },
        ]
        let r: Response = try decode(try await send("POST", URL(string: "\(base)/freeBusy")!, body: body, token: token))
        var out: [String: FreeBusy] = [:]
        for (id, cal) in r.calendars ?? [:] {
            let busy = (cal.busy ?? []).compactMap { b -> DateInterval? in
                guard let s = iso.date(from: b.start), let e = iso.date(from: b.end), e > s else { return nil }
                return DateInterval(start: s, end: e)
            }
            out[id.lowercased()] = FreeBusy(busy: busy, unavailable: !(cal.errors ?? []).isEmpty)
        }
        return out
    }

    struct Draft {
        var title: String
        var start: Date
        var end: Date
        var attendees: [Person]
        var meet: Bool
        var notes: String?
    }

    static func insert(_ d: Draft, calendarID: String, token: String) async throws {
        var body: [String: Any] = [
            "summary": d.title,
            "start": time(d.start),
            "end": time(d.end),
            "attendees": d.attendees.map { ["email": $0.email] },
        ]
        if let notes = d.notes, !notes.isEmpty { body["description"] = notes }
        if d.meet {
            body["conferenceData"] = ["createRequest": ["requestId": UUID().uuidString, "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
        }
        var c = URLComponents(string: "\(base)/calendars/\(escape(calendarID))/events")!
        c.queryItems = [.init(name: "conferenceDataVersion", value: "1"), .init(name: "sendUpdates", value: "all"), .init(name: "fields", value: "id")]
        _ = try await send("POST", c.url!, body: body, token: token)
    }

    /// Only the keys in `changes` are touched; Google sends updates to guests.
    static func patch(calendarID: String, eventID: String, changes: [String: Any], token: String) async throws {
        var c = URLComponents(string: "\(base)/calendars/\(escape(calendarID))/events/\(escape(eventID))")!
        c.queryItems = [.init(name: "sendUpdates", value: "all"), .init(name: "fields", value: "id")]
        _ = try await send("PATCH", c.url!, body: changes, token: token)
    }

    static func delete(calendarID: String, eventID: String, token: String) async throws {
        var c = URLComponents(string: "\(base)/calendars/\(escape(calendarID))/events/\(escape(eventID))")!
        c.queryItems = [.init(name: "sendUpdates", value: "all")]
        _ = try await send("DELETE", c.url!, token: token)
    }

    static func time(_ d: Date) -> [String: String] {
        ["dateTime": iso.string(from: d), "timeZone": TimeZone.current.identifier]
    }

    static func attendeesBody(_ people: [Person]) -> [[String: Any]] {
        people.map { p in
            var a: [String: Any] = ["email": p.email]
            if let s = p.status { a["responseStatus"] = s }
            if p.optional { a["optional"] = true }
            if let n = p.name { a["displayName"] = n }
            return a
        }
    }

    private static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/@#?"))) ?? id
    }

    private static func send(_ method: String, _ url: URL, body: [String: Any]? = nil, token: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await Net.session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(decoding: data, as: UTF8.self)
            if status == 403, text.contains("insufficient") || text.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") {
                throw GoogleError.needsWriteAccess
            }
            throw GoogleError.http(status)
        }
        return data
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}

extension Meeting {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    private static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoFractional.date(from: s)
    }

    /// Returns nil for anything that shouldn't show: all-day, cancelled, declined, working location, out of office.
    init?(google e: GEvent, calendar: GCalendar) {
        guard e.status != "cancelled",
              e.eventType != "workingLocation", e.eventType != "outOfOffice",
              let start = Self.date(e.start?.dateTime), let end = Self.date(e.end?.dateTime),
              e.attendees?.contains(where: { $0.isSelf == true && $0.responseStatus == "declined" }) != true
        else { return nil }

        var link: MeetingLink?
        var known = CallCodes.Known()
        let video = e.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })
        if let video, let uri = video.uri, let url = URL(string: uri) {
            let name = e.conferenceData?.conferenceSolution?.name ?? "Video call"
            link = MeetingLink(url: url, service: name.hasPrefix("Zoom") ? "Zoom" : name)
            // conferenceId is the Meet code or Zoom ID; for other add-ons it can be an opaque thread ID.
            let id = [.meet, .zoom].contains(link?.kind) ? e.conferenceData?.conferenceId : nil
            known = CallCodes.Known(meetingCode: video.meetingCode ?? id, passcode: video.passcode ?? video.password)
        } else if let meet = e.hangoutLink.flatMap(URL.init(string:)) {
            link = MeetingLink(url: meet, service: "Google Meet")
        } else {
            link = LinkDetector.detect([e.location, e.description])
        }
        let notes = Meeting.plainText(fromHTML: e.description)
        link = link?.reading([e.location, notes], known: known)

        let people = (e.attendees ?? []).compactMap { a -> Person? in
            guard let email = a.email else { return nil }
            return Person(email: email, name: a.displayName, status: a.responseStatus, isSelf: a.isSelf == true,
                          organizer: a.organizer == true, optional: a.optional == true, resource: a.resource == true)
        }
        let rooms = people.filter { $0.resource && $0.status != "declined" }.map(\.display)
        let organizer = e.organizer?.isSelf == true || e.attendees == nil

        self.init(
            id: e.id,
            title: (e.summary?.isEmpty == false ? e.summary : nil) ?? "Untitled",
            start: start,
            end: end,
            color: calendar.color,
            calendarName: calendar.name,
            link: link,
            attendees: people.filter { !$0.isSelf && !$0.resource }.map(\.display),
            webURL: e.htmlLink.flatMap(URL.init(string:)),
            room: rooms.isEmpty ? Meeting.place(e.location) : rooms.joined(separator: ", "),
            calendarID: calendar.id,
            people: people, // rooms included, so rewriting the guest list never drops the booking
            notes: notes,
            selfStatus: people.first(where: \.isSelf)?.status,
            isOrganizer: organizer,
            canModify: calendar.writable && (organizer || e.guestsCanModify == true)
        )
    }
}

extension NSColor {
    convenience init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

