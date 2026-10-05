import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = CalendarStore()
    private lazy var model = AppModel(store: store)
    private var status: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }

        // --demo [HH:mm[:ss]] runs on the mockup's meetings at a pretend time.
        if args.contains("--demo") {
            Clock.setDemo(time: value(after: "--demo") ?? "10:18")
            Joiner.dryRun = true
            store.loadDemo()
        } else {
            store.start()
        }

        if let dir = value(after: "--snapshot") {
            Task {
                await Snapshot.run(model: model, store: store, dir: URL(fileURLWithPath: dir))
                exit(0)
            }
            return
        }

        status = StatusItemController(model: model)
        model.start()

        switch value(after: "--show") {
        case "popover": status?.popover.show()
        case "overlay": model.hero.map(model.present)
        case "card": model.meetings.first { $0.isLive(at: Clock.now()) }.map(model.join)
        default: break
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
