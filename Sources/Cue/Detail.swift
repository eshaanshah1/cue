import AppKit
import SwiftUI

// MARK: - Meeting details

struct DetailView: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    let close: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TopBar(back: backLabel) {
                PopMenu.show(menuItems)
            }

            VStack(alignment: .leading, spacing: 0) {
                CalendarLabel(meeting: meeting)
                Text(meeting.title)
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                Text(longRange)
                    .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                    .padding(.top, 4)
                if let room = meeting.room {
                    Label(room, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .padding(.top, 3)
                }
            }
            .padding(.horizontal, 16)

            if let link = meeting.link {
                Button { close(); model.join(meeting) } label: {
                    Label("Join \(link.service)", systemImage: "video.fill").labelStyle(TightLabel())
                }
                .buttonStyle(JoinStyle(height: 30, size: 13, padding: 14))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            if meeting.people.contains(where: \.isSelf), !meeting.isOrganizer {
                HStack {
                    Text("Going?").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    RSVPControl(status: meeting.selfStatus) { reply($0) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }

            PeopleList(people: guests)
                .padding(.horizontal, 8)
                .padding(.top, 12)

            if let notes = meeting.notes {
                Text(notes)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Color.cueRed).padding(.horizontal, 16).padding(.top, 8)
            }

            VStack(spacing: 0) {
                Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1)
                HStack {
                    FooterButton(icon: "arrow.up.right", title: meeting.webURL != nil ? "Open in Google Calendar" : "Open in Calendar") {
                        close()
                        Joiner.openInCalendar(meeting)
                    }
                    Spacer()
                    if meeting.canModify {
                        FooterButton(icon: nil, title: "Edit") { model.edit(meeting) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
            }
            .padding(.top, 14)
        }
        .padding(.top, 10)
    }

    private var guests: [Person] { meeting.people.filter { !$0.resource } }

    private var backLabel: String {
        Calendar.current.isDateInToday(meeting.start) ? "Today" : Calendar.current.isDateInTomorrow(meeting.start) ? "Tomorrow" : "Back"
    }

    private var longRange: String {
        "\(meeting.start.formatted(.dateTime.weekday(.wide).day().month(.wide))), \(Fmt.range(meeting))"
    }

    private var menuItems: [PopMenu.Item] {
        var items: [PopMenu.Item] = [.init("Open in Google Calendar") { close(); Joiner.openInCalendar(meeting) }]
        if let link = meeting.link {
            items.append(.init("Copy \(link.service) link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            })
        }
        if meeting.canModify { items.append(.init("Edit") { model.edit(meeting) }) }
        return items
    }

    private func reply(_ status: String) {
        guard model.store.canWrite else { model.route = .permission; return }
        Task {
            do { try await model.store.rsvp(meeting, status); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

struct TopBar: View {
    let back: String
    var more: (() -> Void)?

    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Button { _ = model.back() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text(back)
                }
                .font(.system(size: 13))
                .foregroundStyle(Color.cueBlue)
                .padding(.leading, 4).padding(.trailing, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if let more {
                Button(action: more) {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

struct CalendarLabel: View {
    let meeting: Meeting
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(nsColor: meeting.color)).frame(width: 7, height: 7)
            Text(meeting.calendarName)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}

struct RSVPControl: View {
    let status: String?
    let set: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            option("Yes", "accepted", check: true)
            option("Maybe", "tentative")
            option("No", "declined")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.fill))
    }

    private func option(_ title: String, _ value: String, check: Bool = false) -> some View {
        let on = status == value
        return Button { if !on { set(value) } } label: {
            HStack(spacing: 4) {
                if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(on ? Color.cueBlue : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.cueBlue.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PeopleList: View {
    let people: [Person]
    var removable: ((Person) -> Void)? = nil
    private static let colors: [NSColor] = [.systemIndigo, .systemOrange, .systemGreen, .systemPink, .systemTeal, .systemPurple]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sorted.prefix(8).enumerated()), id: \.element.email) { i, p in
                PersonRow(person: p, color: p.isSelf ? .systemBlue : Self.colors[i % Self.colors.count], remove: removable.map { r in { r(p) } })
            }
            if sorted.count > 8 {
                Text("and \(sorted.count - 8) more").font(.system(size: 12)).foregroundStyle(Color.tertiary).padding(.horizontal, 8).frame(height: 24)
            }
        }
    }

    /// Organiser first, then everyone else, you last.
    private var sorted: [Person] {
        people.sorted { a, b in
            if a.organizer != b.organizer { return a.organizer }
            if a.isSelf != b.isSelf { return !a.isSelf }
            return false
        }
    }
}

struct PersonRow: View {
    let person: Person
    let color: NSColor
    var remove: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Text(Fmt.initials(person.display).prefix(person.isSelf ? 1 : 2))
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color(nsColor: color)))
                Circle().fill(statusColor).frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            Text(person.isSelf ? "You" : person.display).font(.system(size: 13)).lineLimit(1)
            Spacer()
            if let remove, hover, !person.isSelf {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text(role).font(.system(size: 12)).foregroundStyle(Color.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .onHover { hover = $0 }
    }

    private var role: String {
        if person.organizer { return "Organiser" }
        switch person.status {
        case "accepted": return "Going"
        case "tentative": return "Maybe"
        case "declined": return "Not going"
        default: return person.optional ? "Optional" : "Invited"
        }
    }

    private var statusColor: Color {
        switch person.status {
        case "accepted": return Color(nsColor: .systemGreen)
        case "tentative": return .cueOrange
        case "declined": return .cueRed
        default: return Color(nsColor: .systemGray)
        }
    }
}

// MARK: - Editing

struct EditView: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting

    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var notes: String
    @State private var people: [Person]
    @State private var addingEmail = false
    @State private var email = ""
    @State private var confirmDelete = false
    @State private var saving = false
    @State private var error: String?

    init(meeting: Meeting) {
        self.meeting = meeting
        _title = State(initialValue: meeting.title)
        _start = State(initialValue: meeting.start)
        _end = State(initialValue: meeting.end)
        _notes = State(initialValue: meeting.notes ?? "")
        _people = State(initialValue: meeting.people)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TopBar(back: Calendar.current.isDateInToday(meeting.start) ? "Today" : Calendar.current.isDateInTomorrow(meeting.start) ? "Tomorrow" : "Back")

            VStack(alignment: .leading, spacing: 0) {
                CalendarLabel(meeting: meeting)
                Group {
                    if Snapshot.active {
                        Snapshot.tinted(title, [], size: 17).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TokenField(text: $title, tokens: [], placeholder: "Title", fontSize: 17, onSubmit: save, onCancel: { _ = model.back() })
                    }
                }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.fill))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.cueBlue.opacity(0.65), lineWidth: 1.5))
                    .padding(.top, 6)
                HStack(spacing: 6) {
                    Chip(text: start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) { PopMenu.show(dayItems) }
                    Chip(text: Fmt.time(start)) { PopMenu.show(startItems) }
                    Text("–").foregroundStyle(.secondary)
                    Chip(text: Fmt.time(end)) { PopMenu.show(endItems) }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 16)

            PeopleList(people: people.filter { !$0.resource }) { p in people.removeAll { $0.email == p.email } }
                .padding(.horizontal, 8)
                .padding(.top, 12)

            if addingEmail {
                TokenField(text: $email, tokens: [], placeholder: "Name or email", fontSize: 13,
                           onSubmit: addEmail, onCancel: { addingEmail = false })
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.fill))
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            } else {
                Button { PopMenu.show(addItems) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        Text("Add person")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Color.cueBlue)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Group {
                if Snapshot.active {
                    Text(notes).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.horizontal, 5).padding(.top, 2)
                } else {
                    TextEditor(text: $notes).scrollContentBackground(.hidden)
                }
            }
                .font(.system(size: 12.5))
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.fill))
                .padding(.horizontal, 16)
                .padding(.top, 10)

            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Color.cueRed).padding(.horizontal, 16).padding(.top, 8)
            }

            VStack(spacing: 0) {
                Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1)
                HStack(spacing: 8) {
                    if confirmDelete {
                        Text("Delete for everyone?").font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 8)
                        Spacer()
                        Button("Keep") { confirmDelete = false }.buttonStyle(SecondaryStyle(height: 30, size: 13, padding: 14))
                        Button("Delete", action: delete).buttonStyle(DestructiveStyle())
                    } else {
                        if meeting.isOrganizer {
                            Button { confirmDelete = true } label: {
                                Label("Delete", systemImage: "trash").labelStyle(TightLabel())
                                    .font(.system(size: 13)).foregroundStyle(Color.cueRed)
                                    .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Button("Cancel") { _ = model.back() }.buttonStyle(SecondaryStyle(height: 30, size: 13, padding: 14))
                        Button(action: save) {
                            HStack(spacing: 4) {
                                Text(saving ? "Saving…" : "Save")
                                Text("⌘S").font(.system(size: 11, weight: .medium)).opacity(0.75)
                            }
                        }
                        .buttonStyle(JoinStyle(height: 30, size: 13, padding: 14))
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
            }
            .padding(.top, 14)
        }
        .padding(.top, 10)
    }

    // MARK: Menus

    private var dayItems: [PopMenu.Item] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Clock.now())
        return (0..<14).map { i in
            let d = cal.date(byAdding: .day, value: i, to: today)!
            return .init(d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)), checked: cal.isDate(d, inSameDayAs: start)) {
                let hm = cal.dateComponents([.hour, .minute], from: start)
                let length = end.timeIntervalSince(start)
                start = cal.date(bySettingHour: hm.hour!, minute: hm.minute!, second: 0, of: d)!
                end = start.addingTimeInterval(length)
            }
        }
    }

    private var startItems: [PopMenu.Item] {
        let day = Calendar.current.startOfDay(for: start)
        let length = end.timeIntervalSince(start)
        return stride(from: 7.0, through: 21.5, by: 0.5).map { h in
            let t = day.addingTimeInterval(h * 3600)
            return .init(Fmt.time(t), checked: t == start) { start = t; end = t.addingTimeInterval(length) }
        }
    }

    private var endItems: [PopMenu.Item] {
        [15, 30, 45, 60, 90, 120].map { m in
            let t = start.addingTimeInterval(TimeInterval(m * 60))
            let label = m < 60 ? "\(m) min" : m == 60 ? "1 hr" : m == 90 ? "1.5 hr" : "2 hr"
            return .init("\(Fmt.time(t))   (\(label))", checked: t == end) { end = t }
        }
    }

    private var addItems: [PopMenu.Item] {
        let have = Set(people.map { $0.email.lowercased() })
        var items: [PopMenu.Item] = model.store.contacts.filter { !have.contains($0.email.lowercased()) }.prefix(12).map { p in
            .init(p.name.map { "\($0)  (\(p.email))" } ?? p.email) { people.append(Person(email: p.email, name: p.name, status: "needsAction")) }
        }
        if !items.isEmpty { items.append(.separator) }
        items.append(.init("Type a name or email…") { addingEmail = true })
        return items
    }

    private func addEmail() {
        let e = email.trimmingCharacters(in: .whitespaces)
        email = ""
        addingEmail = false
        func add(_ p: Person) {
            if !people.contains(where: { $0.email.caseInsensitiveCompare(p.email) == .orderedSame }) {
                people.append(Person(email: p.email, name: p.name, status: "needsAction"))
            }
        }
        if e.contains("@") { add(Person(email: e)); return }
        guard !e.isEmpty else { return }
        let q = e.lowercased()
        if let p = model.store.contacts.first(where: { ($0.name ?? "").lowercased().hasPrefix(q) || $0.email.lowercased().hasPrefix(q) }) {
            add(p)
        } else {
            error = "Couldn’t find \(e). Type their email."
        }
    }

    // MARK: Actions

    private func save() {
        var changes: [String: Any] = [:]
        let t = title.trimmingCharacters(in: .whitespaces)
        if t != meeting.title { changes["summary"] = t }
        if start != meeting.start || end != meeting.end {
            changes["start"] = GoogleCalendarAPI.time(start)
            changes["end"] = GoogleCalendarAPI.time(end)
        }
        if notes != (meeting.notes ?? "") { changes["description"] = notes }
        if people != meeting.people { changes["attendees"] = GoogleCalendarAPI.attendeesBody(people) }
        guard !changes.isEmpty else { _ = model.back(); return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.store.update(meeting, changes: changes)
                model.route = .main
            } catch GoogleError.needsWriteAccess {
                model.route = .permission
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func delete() {
        Task {
            do {
                try await model.store.delete(meeting)
                model.route = .main
            } catch {
                self.error = error.localizedDescription
                confirmDelete = false
            }
        }
    }
}

struct DestructiveStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(Color.cueRed.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

// MARK: - Asking for edit access

struct PermissionView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Allow Cue to change your calendar").font(.system(size: 15, weight: .semibold))
            Text("Adding events, editing and replying need one more permission from Google. Your current sign-in only lets Cue read.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Sign in again") {
                    model.route = .main
                    model.store.signInWithGoogle()
                }
                .buttonStyle(JoinStyle(height: 28, size: 12, padding: 12))
                Button("Not now") { model.route = .main }.buttonStyle(SecondaryStyle())
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}
