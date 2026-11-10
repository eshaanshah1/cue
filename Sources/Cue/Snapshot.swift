import AppKit
import SwiftUI

/// `--snapshot <dir>` renders every surface offscreen in light and dark, then quits.
/// Used to check layout against the mockups without touching the real screen.
enum Snapshot {
    static var active = false
    static var showsHover = false

    @MainActor
    static func run(model: AppModel, store: CalendarStore, dir: URL) async {
        active = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func save(_ name: String, size: CGSize? = nil, _ view: some View) {
            for scheme in [ColorScheme.light, .dark] {
                let content = ZStack {
                    Backdrop(scheme: scheme)
                    view.environmentObject(model).frame(width: size?.width, height: size?.height).padding(48)
                }
                .environment(\.colorScheme, scheme)
                .fixedSize()
                let r = ImageRenderer(content: content)
                r.scale = 2
                guard let cg = r.cgImage,
                      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        func at(_ t: String) { Clock.setDemo(time: t); model.freeze() }

        // Popover at 10:18, row hovered state is not rendered offscreen.
        at("10:18")
        save("popover", PopoverView(close: {}))

        // Menu bar states.
        let bar = ["21:00", "07:00", "09:50", "10:24", "10:29:30", "10:37", "10:43"].map { t -> AppModel.BarState in at(t); return model.barState }
        save("menubar", BarStrip(states: bar))

        // Overlay 42 seconds before standup, sized like 80% of a 1600×970 screen.
        at("10:29:18")
        let standup = store.meetings[2]
        save("overlay", size: CGSize(width: 1280, height: 776), OverlayView(meeting: standup))
        at("10:59:18")
        save("overlay-zoom", size: CGSize(width: 1280, height: 776), OverlayView(meeting: store.meetings[3]))
        at("10:29:18")

        // Mini card states.
        showsHover = true
        func card(_ t: String) -> some View {
            Clock.setDemo(time: t)
            return MiniCard(meeting: standup, now: Clock.now())
        }
        save("card", VStack(alignment: .leading, spacing: 28) {
            card("10:29:18")
            card("10:37")
            card("10:43")
        })
        showsHover = false

        // Add, find a time, details, edit.
        at("10:18")
        func chrome(_ v: some View) -> some View { v.frame(width: 360).padding(.bottom, 6).glass(20) }
        let a = ComposeModel(store: store)
        a.text = "Design sync with Priya tomorrow at 3pm"
        await a.loadBusyNow()
        save("compose-conflict", chrome(ComposeView(c: a)))
        a.text = "Design sync with Priya tomorrow at 4pm"
        await a.loadBusyNow()
        save("compose-ok", chrome(ComposeView(c: a)))
        let d = ComposeModel(store: store)
        d.text = "Sync with Sanket today at 6.30"
        await d.loadBusyNow()
        save("compose-unknown", chrome(ComposeView(c: d)))
        let f = ComposeModel(store: store)
        f.text = "Sync with Priya and Rahul tomorrow 45m"
        await f.loadBusyNow()
        save("findtime", chrome(ComposeView(c: f)))
        let oneOnOne = store.meetings[5]
        save("detail", chrome(DetailView(meeting: oneOnOne, close: {})))
        save("peek", VStack(alignment: .leading, spacing: 28) {
            PeekView(meeting: oneOnOne, now: model.now)
            PeekView(meeting: store.meetings[3], now: model.now)
        })
        var mine = oneOnOne
        mine.isOrganizer = true
        save("edit", chrome(EditView(meeting: mine)))

        // Dragging a meeting on the ribbon: one strip for 5+ guests, lanes for fewer.
        let cal = Calendar.current
        func today(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: Clock.now())! }
        let harness = store.meetings[3]
        func moving(_ m: Meeting, to h: Int, _ min: Int, dropped: Bool) async {
            model.endMove()
            let mv = model.beginMove(m)
            await mv.loadBusyNow()
            mv.pick(today(h, min))
            mv.dropped = dropped
        }
        await moving(harness, to: 12, 15, dropped: false)
        save("move-strip", PopoverView(close: {}))
        await moving(harness, to: 13, 30, dropped: true)
        save("move-strip-drop", PopoverView(close: {}))
        var four = harness
        four.people = harness.people.filter { p in p.isSelf || ["rahul", "priya", "aman", "neha"].contains { p.email.hasPrefix($0) } }
        await moving(four, to: 11, 45, dropped: false)
        save("move-lanes", PopoverView(close: {}))
        var theirs = store.meetings[6]
        theirs.canModify = false
        theirs.isOrganizer = false
        await moving(theirs, to: 12, 0, dropped: true)
        save("move-propose", PopoverView(close: {}))
        model.endMove()
        save("permission", chrome(PermissionView()))
    }

    static func tinted(_ text: String, _ tokens: [NSRange], size: CGFloat) -> Text {
        var a = AttributedString(text)
        for r in tokens {
            guard let range = Range(r, in: text), let lo = AttributedString.Index(range.lowerBound, within: a),
                  let hi = AttributedString.Index(range.upperBound, within: a) else { continue }
            a[lo..<hi].foregroundColor = .cueBlue
        }
        return Text(a).font(.system(size: size))
    }
}

private struct Backdrop: View {
    let scheme: ColorScheme
    var body: some View {
        if scheme == .dark {
            LinearGradient(colors: [Color(red: 0.11, green: 0.2, blue: 0.38), Color(red: 0.07, green: 0.08, blue: 0.11), Color(red: 0.2, green: 0.1, blue: 0.27)], startPoint: .topTrailing, endPoint: .bottomLeading)
        } else {
            LinearGradient(colors: [Color(red: 0.81, green: 0.89, blue: 1), Color(red: 0.93, green: 0.95, blue: 0.97), Color(red: 0.96, green: 0.85, blue: 0.91)], startPoint: .topTrailing, endPoint: .bottomLeading)
        }
    }
}

/// The menu bar item as it would draw, for each state.
private struct BarStrip: View {
    let states: [AppModel.BarState]

    var body: some View {
        VStack(alignment: .trailing, spacing: 14) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                Group {
                    if let img = BarArt.image(for: s) {
                        if img.isTemplate { Image(nsImage: img).renderingMode(.template) } else { Image(nsImage: img) }
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
        }
        .frame(width: 260, alignment: .trailing)
    }
}
