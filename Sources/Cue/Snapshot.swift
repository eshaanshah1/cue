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

        // Mini card states.
        showsHover = true
        func card(_ t: String, joined: Bool) -> some View {
            Clock.setDemo(time: t)
            return MiniCard(meeting: standup, joined: joined, now: Clock.now())
        }
        save("card", VStack(alignment: .leading, spacing: 28) {
            card("10:29:18", joined: false)
            card("10:37", joined: true)
            card("10:43", joined: true)
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
