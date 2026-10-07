import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Shared look

extension Color {
    static let cueBlue = Color(nsColor: .systemBlue)
    static let cueRed = Color(nsColor: .systemRed)
    static let cueOrange = Color(nsColor: .systemOrange)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let fill = Color.primary.opacity(0.07)
}

/// The system's behind-window blur, clipped to a rounded rect with a mask image so the
/// window shadow follows the corners.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.maskImage = Self.mask(radius)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}

    private static func mask(_ r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

struct Glass: ViewModifier {
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                if Snapshot.active {
                    RoundedRectangle(cornerRadius: radius, style: .circular)
                        .fill(scheme == .dark ? Color(red: 0.16, green: 0.17, blue: 0.2).opacity(0.92) : Color(white: 0.985).opacity(0.9))
                        .shadow(color: .black.opacity(0.22), radius: 25, y: 12)
                } else {
                    VisualEffect(radius: radius)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .circular)
                    .strokeBorder(Color.white.opacity(scheme == .dark ? 0.14 : 0.7), lineWidth: 0.5)
            )
    }
}

extension View {
    func glass(_ radius: CGFloat) -> some View { modifier(Glass(radius: radius)) }
}

struct JoinStyle: ButtonStyle {
    var height: CGFloat = 32
    var size: CGFloat = 13
    var padding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, padding)
            .frame(height: height)
            .background(Capsule().fill(Color.cueBlue.opacity(configuration.isPressed ? 0.8 : 1)))
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
            .shadow(color: Color.cueBlue.opacity(0.35), radius: 1.5, y: 1)
            .contentShape(Capsule())
    }
}

struct SecondaryStyle: ButtonStyle {
    var height: CGFloat = 28
    var size: CGFloat = 12
    var padding: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, padding)
            .frame(height: height)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.13 : 0.07)))
            .contentShape(Capsule())
    }
}

struct KeyHint: View {
    let key: String
    var onBlue = false

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(onBlue ? Color.white : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(onBlue ? Color.white.opacity(0.22) : Color.fill))
    }
}

struct Ring: View {
    var fraction: Double
    var color: Color
    var width: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: width)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(width / 2)
    }
}

extension EnvironmentValues {
    /// Reports the meeting under the pointer and its frame in the popover window; nil when the pointer leaves.
    @Entry var peek: (Meeting, CGRect?) -> Void = { _, _ in }
}

/// 24h locales print "10:30", 12h ones "10:30 AM"; size the time column to fit either.
private let timeColumn: CGFloat = Fmt.time(Date()).contains(where: \.isLetter) ? 62 : 40

// MARK: - Popover

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    let close: () -> Void
    var onSize: (CGSize) -> Void = { _ in }

    var body: some View {
        Group {
            switch model.route {
            case .main:
                main
            case .compose:
                if let c = model.compose { ComposeView(c: c) } else { main }
            case .detail(let key):
                if let m = model.meeting(key) { DetailView(meeting: m, close: close) } else { main }
            case .edit(let key):
                if let m = model.meeting(key) { EditView(meeting: m).id(key) } else { main }
            case .permission:
                PermissionView()
            }
        }
        .frame(width: model.route == .main ? 340 : 360)
        .padding(.bottom, 6)
        .glass(20)
        .focusEffectDisabled()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.store.access {
            case .denied: AccessView()
            case .unknown: AccessView(waiting: true)
            case .needsGoogle: GoogleSignInView()
            case .granted: content
            }
            footer
        }
        .padding(.top, 16)
    }

    @ViewBuilder private var content: some View {
        if let m = model.hero {
            HeroView(meeting: m, now: model.now, join: { act { model.join(m) } }, open: { model.open(m) })
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("No more meetings today").font(.system(size: 17, weight: .semibold))
                Text("Enjoy the quiet.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        RibbonView(meetings: model.today, now: model.now, highlight: model.hero?.key)
            .padding(.horizontal, 16)
        VStack(alignment: .leading, spacing: 0) {
            section("Later today", model.laterToday)
            section("Tomorrow", model.tomorrow)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    @ViewBuilder private func section(_ title: String, _ items: [Meeting]) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(items, id: \.key) { m in
                MeetingRow(meeting: m, open: { model.open(m) }, join: { act { model.join(m) } })
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1)
            HStack(spacing: 0) {
                if model.store.canCreate && model.store.access == .granted {
                    FooterButton(icon: "plus", title: "New event", hint: "⌘N", tint: .cueBlue) { model.newEvent() }
                        .keyboardShortcut("n", modifiers: .command)
                    Spacer()
                    FooterButton(icon: "calendar", title: nil) { act { Joiner.openCalendarApp(google: model.store.source == .google) } }
                        .help("Open Google Calendar")
                } else {
                    FooterButton(icon: "calendar", title: "Open Calendar") { act { Joiner.openCalendarApp(google: model.store.source == .google) } }
                    Spacer()
                }
                if Snapshot.active {
                    Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 28)
                } else {
                    SettingsMenu()
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
        }
        .padding(.top, 8)
    }

    private func act(_ f: () -> Void) {
        close()
        f()
    }
}

struct HeroView: View {
    let meeting: Meeting
    let now: Date
    let join: () -> Void
    var open: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Fmt.relative(meeting, now: now))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.cueBlue)
                    .monospacedDigit()
                Text(meeting.title)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
                    .lineLimit(1)
                    .padding(.top, 2)
                HStack(spacing: 6) {
                    Text(Fmt.range(meeting)).monospacedDigit()
                    if let link = meeting.link {
                        Image(systemName: "video").font(.system(size: 11)).padding(.leading, 10)
                        Text(link.service)
                    }
                }
                .lineLimit(1)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 3)
                if let room = meeting.room {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 11))
                        Text(room).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            Spacer(minLength: 0)
            if meeting.link != nil {
                Button(action: join) {
                    Label("Join", systemImage: "video.fill").labelStyle(TightLabel())
                }
                .buttonStyle(JoinStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12, weight: .semibold))
            configuration.title
        }
    }
}

/// Today from 8 to 8 (stretched if meetings fall outside), with a red line for now.
struct RibbonView: View {
    let meetings: [Meeting]
    let now: Date
    let highlight: String?
    @Environment(\.peek) private var peek
    @State private var hovered: String?

    private var hours: (Double, Double) {
        let cal = Calendar.current
        let h = { (d: Date) in Double(cal.component(.hour, from: d)) + Double(cal.component(.minute, from: d)) / 60 }
        let lo = min(8, meetings.map { floor(h($0.start)) }.min() ?? 8)
        let hi = max(20, meetings.map { ceil(h($0.end) == 0 ? 24 : h($0.end)) }.max() ?? 20)
        return (lo, min(24, hi))
    }

    var body: some View {
        let (lo, hi) = hours
        let day = Calendar.current.startOfDay(for: now)
        let pos = { (d: Date) in (d.timeIntervalSince(day) / 3600 - lo) / (hi - lo) }
        GeometryReader { geo in
            let w = geo.size.width
            let g = geo.frame(in: .global)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)).frame(height: 18)
                ForEach(meetings, id: \.key) { m in
                    let x = max(0, pos(m.start)) * w
                    let bw = max(3, min(1, pos(m.end)) * w - x - 2)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: m.color).opacity(m.end <= now ? 0.35 : 1))
                        .frame(width: bw, height: 18)
                        .background {
                            if hovered == m.key {
                                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary, lineWidth: 1.5).padding(-3)
                            }
                        }
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { hovered = m.key } else if hovered == m.key { hovered = nil }
                            peek(m, inside ? CGRect(x: g.minX + x, y: g.minY, width: bw, height: 18) : nil)
                        }
                        .offset(x: x)
                        .zIndex(hovered == m.key ? 1 : 0)
                }
                ForEach(Array(stride(from: ceil(lo / 3) * 3, through: hi, by: 3)).filter { $0 > lo && $0 < hi }, id: \.self) { hr in
                    Text("\(Int(hr))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.tertiary)
                        .monospacedDigit()
                        .fixedSize()
                        .frame(width: 30)
                        .offset(x: (hr - lo) / (hi - lo) * w - 15, y: 22)
                }
                let p = pos(now)
                if p >= 0 && p <= 1 {
                    ZStack(alignment: .top) {
                        Capsule().fill(Color.cueRed).frame(width: 2, height: 26)
                        Circle().fill(Color.cueRed).frame(width: 8, height: 8).offset(y: -3)
                    }
                    .frame(width: 8)
                    .offset(x: p * w - 4, y: -4)
                }
            }
        }
        .frame(height: 40)
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let open: () -> Void
    let join: () -> Void
    @State private var hover = false
    @State private var camHover = false
    @State private var frame = CGRect.zero
    @Environment(\.peek) private var peek

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: meeting.color)).frame(width: 3, height: 16)
            Text(Fmt.time(meeting.start))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: timeColumn, alignment: .leading)
            Text(meeting.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let link = meeting.link {
                Button(action: join) {
                    Image(systemName: camHover ? "video.fill" : "video")
                        .font(.system(size: 12))
                        .foregroundStyle(hover ? Color.cueBlue : Color.tertiary)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { camHover = $0 }
                .help("Join on \(link.service)")
            }
        }
        .font(.system(size: 13))
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onHover {
            hover = $0
            peek(meeting, $0 ? frame : nil)
        }
    }
}

/// What hovering a meeting shows beside the popover. Read-only; clicking the meeting opens the full details.
struct PeekView: View {
    let meeting: Meeting
    let now: Date

    private static let colors: [NSColor] = [.systemIndigo, .systemOrange, .systemGreen, .systemPink, .systemTeal, .systemPurple]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if !meeting.calendarName.isEmpty {
                    Circle().fill(Color(nsColor: meeting.color)).frame(width: 7, height: 7)
                    Text(meeting.calendarName).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(when).fontWeight(.semibold).foregroundStyle(meeting.end <= now ? Color.tertiary : Color.cueBlue).monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Text(meeting.title)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                line("clock", "\(Fmt.range(meeting)) · \(duration)")
                if let link = meeting.link { line("video", link.service) }
                if let room = meeting.room { line("mappin.and.ellipse", room) }
            }
            .padding(.top, 4)
            if let who {
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(Array(avatars.enumerated()), id: \.offset) { i, a in
                            Text(a.initials)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color(nsColor: a.isSelf ? .systemBlue : Self.colors[i % Self.colors.count])))
                        }
                    }
                    Text(who).lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            }
            if let notes = meeting.notes {
                Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1).padding(.top, 10)
                Text(notes)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 280, alignment: .leading)
        .glass(16)
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Color.tertiary).frame(width: 13)
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var when: String {
        if meeting.end <= now { return "Ended" }
        if meeting.start <= now { return "Now" }
        if !Calendar.current.isDate(meeting.start, inSameDayAs: now) { return "Tomorrow" }
        let mins = Fmt.minutes(meeting.start.timeIntervalSince(now))
        let h = mins / 60, r = mins % 60
        return h == 0 ? "In \(mins) min" : r == 0 ? "In \(h) hr" : "In \(h) hr \(r) min"
    }

    private var duration: String {
        let mins = Int(meeting.end.timeIntervalSince(meeting.start) / 60)
        let h = mins / 60, r = mins % 60
        return h == 0 ? "\(mins) min" : r == 0 ? "\(h) hr" : "\(h) hr \(r) min"
    }

    /// Google gives people with roles; macOS Calendar only names.
    private var others: [String] {
        let guests = meeting.people.filter { !$0.resource && !$0.isSelf }.sorted { $0.organizer && !$1.organizer }
        return meeting.people.isEmpty ? meeting.attendees : guests.map(\.display)
    }

    private var withYou: Bool { meeting.people.contains(where: \.isSelf) }

    private var who: String? {
        switch others.count {
        case 0: return nil
        case 1: return withYou ? "\(others[0]) and you" : others[0]
        default: return Fmt.people(others)
        }
    }

    private var avatars: [(initials: String, isSelf: Bool)] {
        var out = others.prefix(4).map { (Fmt.initials($0), false) }
        if others.count == 1, withYou, let me = meeting.people.first(where: \.isSelf) {
            out.append((String(Fmt.initials(me.display).prefix(1)), true))
        }
        return out
    }
}

struct FooterButton: View {
    let icon: String?
    let title: String?
    var hint: String? = nil
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: tint == nil ? .regular : .semibold)) }
                if let title { Text(title).fontWeight(tint == nil ? .regular : .medium) }
                if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(Color.tertiary) }
            }
            .font(.system(size: 13))
            .foregroundStyle(tint ?? Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SettingsMenu: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("alertsEnabled") private var alerts = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let store = model.store
        Menu {
            Picker("Calendars from", selection: Binding(get: { store.source }, set: { store.setSource($0) })) {
                Text("Google Calendar").tag(CalendarStore.Source.google)
                Text("macOS Calendar").tag(CalendarStore.Source.macos)
            }
            .pickerStyle(.inline)
            if store.source == .google {
                if let email = store.googleEmail {
                    Text(email)
                    Button("Sign out of Google") { store.signOutOfGoogle() }
                } else {
                    Button("Sign in with Google…") { store.signInWithGoogle() }
                }
            }
            Divider()
            Toggle("Show meeting alerts", isOn: $alerts)
            Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { on in
                try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }))
            Divider()
            Button("Quit Cue") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}

struct GoogleSignInView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let store = model.store
        VStack(alignment: .leading, spacing: 4) {
            switch store.googleState {
            case .signingIn:
                Text("Finish signing in in your browser").font(.system(size: 15, weight: .semibold))
                Text("Cue asks Google for read-only access to your calendar.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Cancel") { store.cancelGoogleSignIn() }
                    .buttonStyle(SecondaryStyle())
                    .padding(.top, 8)
            default:
                Text(store.googleState == .expired ? "Sign in to Google again" : "Connect Google Calendar")
                    .font(.system(size: 15, weight: .semibold))
                Group {
                    if case .failed(let message) = store.googleState {
                        Text(message).foregroundStyle(Color.cueRed)
                    } else if store.googleState == .expired {
                        Text("Your Google sign-in expired. Your meetings come back as soon as you sign in.")
                    } else {
                        Text("Cue reads your calendar, read-only. Events stay on this Mac.")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Sign in with Google") { store.signInWithGoogle() }
                        .buttonStyle(JoinStyle(height: 28, size: 12, padding: 12))
                    Button("Use macOS Calendar") { store.setSource(.macos) }
                        .buttonStyle(SecondaryStyle())
                }
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

struct AccessView: View {
    var waiting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(waiting ? "Waiting for calendar access" : "Cue can’t see your calendars")
                .font(.system(size: 15, weight: .semibold))
            Text("Allow Cue under Privacy & Security, Calendars. Google and Outlook calendars show up once they’re added in Internet Accounts.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !waiting {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
                .buttonStyle(SecondaryStyle())
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

// MARK: - Overlay

struct OverlayView: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting

    private static let avatarColors: [NSColor] = [.systemIndigo, .systemOrange, .systemGreen, .systemPink, .systemTeal, .systemPurple]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    countdown(Clock.now())
                }
                Text(meeting.title)
                    .font(.system(size: 46, weight: .semibold))
                    .tracking(-0.8)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 34)
                    .padding(.horizontal, 60)
                HStack(spacing: 22) {
                    Text(Fmt.range(meeting)).monospacedDigit()
                    if let link = meeting.link {
                        HStack(spacing: 7) {
                            Image(systemName: "video")
                            Text(link.service)
                        }
                    }
                    if let room = meeting.room {
                        HStack(spacing: 7) {
                            Image(systemName: "mappin.and.ellipse")
                            Text(room).lineLimit(1)
                        }
                    }
                }
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                if !meeting.attendees.isEmpty { people.padding(.top, 26) }
                actions.padding(.top, 40)
            }
            VStack {
                HStack {
                    HStack(spacing: 8) {
                        Circle().fill(Color(nsColor: meeting.color)).frame(width: 8, height: 8)
                        Text(meeting.calendarName)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button { model.minimize() } label: {
                        HStack(spacing: 6) {
                            Text("Minimize")
                            Text("esc").opacity(0.7).font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(SecondaryStyle(height: 30, size: 12, padding: 11))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Text("Click outside or press esc to minimize. Dismiss closes it for good.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glass(34)
        .focusEffectDisabled()
    }

    private func countdown(_ now: Date) -> some View {
        let left = meeting.start.timeIntervalSince(now)
        let started = left <= 0
        return ZStack {
            Ring(fraction: started ? 1 : left / 60, color: .cueBlue, width: 9)
            VStack(spacing: 6) {
                Text(started ? "Now" : Fmt.countdown(left))
                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                    .tracking(-1)
                    .monospacedDigit()
                Text(started ? startedText(-left) : "until it starts")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 210, height: 210)
    }

    private func startedText(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        return m < 1 ? "it’s starting" : m == 1 ? "started 1 min ago" : "started \(m) min ago"
    }

    private var people: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                ForEach(Array(meeting.attendees.prefix(5).enumerated()), id: \.offset) { i, name in
                    Text(Fmt.initials(name))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color(nsColor: Self.avatarColors[i % Self.avatarColors.count])))
                }
            }
            Text(Fmt.people(meeting.attendees))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if meeting.link != nil {
                Button { model.join(meeting) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "video.fill").font(.system(size: 16, weight: .semibold))
                        Text("Join")
                        KeyHint(key: "↩", onBlue: true)
                    }
                }
                .buttonStyle(JoinStyle(height: 50, size: 17, padding: 28))
                .keyboardShortcut(.defaultAction)
            }
            Button("Remind me in 1 min") { model.snooze() }
                .buttonStyle(SecondaryStyle(height: 50, size: 15, padding: 22))
            Button("Dismiss") { model.dismiss() }
                .buttonStyle(SecondaryStyle(height: 50, size: 15, padding: 22))
        }
    }
}

// MARK: - Mini card

struct MiniCardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let m = model.active {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    MiniCard(meeting: m, joined: model.activeJoined, now: Clock.now())
                }
            }
        }
        .padding(MiniCardController.margin)
        .focusEffectDisabled()
    }
}

struct MiniCard: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    let joined: Bool
    let now: Date
    @State private var hover = false

    var body: some View { card(meeting, now: now) }

    private func card(_ m: Meeting, now: Date) -> some View {
        let live = now >= m.start
        let left = m.end.timeIntervalSince(now)
        let wrapping = live && left <= 3 * 60
        let tint: Color = wrapping ? .cueOrange : .cueBlue
        let next = model.meetings.first { $0.start >= m.end && Calendar.current.isDate($0.start, inSameDayAs: now) }

        let kicker: String
        let sub: String
        if !live {
            kicker = "Starts in \(Fmt.countdown(m.start.timeIntervalSince(now)))"
            sub = ([Fmt.range(m), m.link?.service, m.room].compactMap { $0 }).joined(separator: ", ")
        } else {
            let mins = Fmt.minutes(left)
            kicker = wrapping ? "Ends in \(mins) min" : (joined ? "In call, \(mins) min left" : "Started, \(mins) min left")
            sub = next.map { "Next: \($0.title) at \(Fmt.time($0.start))" } ?? "Nothing after this"
        }
        let fraction = live ? left / m.end.timeIntervalSince(m.start) : m.start.timeIntervalSince(now) / 60

        return HStack(spacing: 12) {
            ZStack {
                Ring(fraction: fraction, color: tint, width: 2.5)
                if live {
                    Text("\(Fmt.minutes(left))m").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                } else {
                    Image(systemName: "video").font(.system(size: 13, weight: .medium)).foregroundStyle(tint)
                }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(kicker).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).monospacedDigit()
                Text(m.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            }
            Spacer(minLength: 0)
            if joined {
                Button("Back to call") { model.backToCall() }.buttonStyle(SecondaryStyle())
            } else if m.link != nil {
                Button("Join") { model.join(m) }.buttonStyle(JoinStyle(height: 28, size: 12, padding: 12))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(width: 364)
        .glass(20)
        .contentShape(Rectangle())
        .onTapGesture { model.expand() }
        .gesture(WindowDragGesture())
        .overlay(alignment: .topLeading) {
            Button { model.closeCard() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .glass(10)
            }
            .buttonStyle(.plain)
            .offset(x: -7, y: -7)
            .opacity(hover || Snapshot.showsHover ? 1 : 0)
        }
        .onHover { hover = $0 }
        .help(joined ? "Click to go back to the call. Drag to move." : "Click to expand. Drag to move.")
    }
}
