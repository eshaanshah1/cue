import AppKit
import Combine
import SwiftUI

/// Borderless panel that can take keyboard focus without activating Cue (Spotlight-style).
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    private let keyable: Bool

    init(level: NSWindow.Level, keyable: Bool = true) {
        self.keyable = keyable
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.level = level
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

private func fade(_ windows: [NSWindow], in show: Bool, done: (() -> Void)? = nil) {
    let duration = reduceMotion ? 0 : (show ? 0.18 : 0.14)
    if show { windows.forEach { $0.alphaValue = 0 } }
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = duration
        windows.forEach { $0.animator().alphaValue = show ? 1 : 0 }
    }, completionHandler: done)
}

private func screenUnderMouse() -> NSScreen {
    NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

// MARK: - Popover

@MainActor
final class PopoverController {
    private let model: AppModel
    private weak var button: NSStatusBarButton?
    private var panel: FloatingPanel?
    private var host: NSHostingView<AnyView>?
    private var bag = Set<AnyCancellable>()
    private var resignObserver: Any?
    private var closedAt = Date.distantPast
    private var peek: PeekController?

    init(model: AppModel, button: NSStatusBarButton?) {
        self.model = model
        self.button = button
    }

    var isVisible: Bool { panel != nil }

    func toggle() {
        if isVisible { close() } else if Date().timeIntervalSince(closedAt) > 0.25 { show() }
    }

    func show() {
        guard panel == nil else { return }
        model.store.refreshIfStale()
        let panel = FloatingPanel(level: .popUpMenu)
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if !self.model.back() { self.close() }
        }
        // Built fresh on every open and dropped on close, so nothing sits in memory while hidden.
        let peek = PeekController(model: model, owner: panel)
        let root = PopoverView(close: { [weak self] in self?.close() }, onSize: { [weak self] size in self?.layout(size) })
            .environment(\.peek) { [weak peek] m, rect in peek?.hover(m, at: rect) }
        let host = NSHostingView(rootView: AnyView(root.environmentObject(model)))
        self.peek = peek
        model.$route.dropFirst().sink { [weak peek] _ in peek?.hide() }.store(in: &bag)
        panel.contentView = host
        self.panel = panel
        self.host = host
        layout(host.fittingSize)
        panel.makeKeyAndOrderFront(nil)
        fade([panel], in: true)
        button?.highlight(true)
        DispatchQueue.main.async { panel.invalidateShadow() }

        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // A chip's menu takes focus for a moment; that isn't the person leaving.
                guard let self, NSApp.keyWindow == nil || NSApp.keyWindow === self.panel else { return }
                if self.menuTracking { return }
                self.close()
            }
        }
        menuObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTracking = true }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuTracking = false
                    self?.panel?.makeKey()
                }
            },
        ]
    }

    private var menuTracking = false
    private var menuObservers: [Any] = []

    private func layout(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        // Menu bar managers (Ice, Bartender) and the notch can push the item off-screen.
        // Then there's nothing to hang from, so open at the top-right under the menu bar.
        let anchor = button?.window?.frame
        let screen = button?.window?.screen ?? NSScreen.main ?? screenUnderMouse()
        let visible = screen.visibleFrame
        let inMenuBar = anchor.map { $0.minX >= screen.frame.minX && $0.maxX <= screen.frame.maxX && $0.minY >= visible.maxY - 4 } ?? false
        var x = inMenuBar ? anchor!.midX - size.width / 2 : visible.maxX - size.width
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = inMenuBar ? anchor!.minY - 6 : visible.maxY - 6
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    func close() {
        guard let panel else { return }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers = []
        bag.removeAll()
        peek?.hide()
        peek = nil
        if model.route != .compose { model.route = .main }
        self.panel = nil
        host = nil
        closedAt = Date()
        button?.highlight(false)
        fade([panel], in: false) { panel.orderOut(nil) }
    }
}

// MARK: - Hover peek

/// The details card that floats beside the popover while a meeting is hovered.
/// It never takes the mouse, so moving down the list just moves the card along.
@MainActor
final class PeekController {
    private unowned let model: AppModel
    private weak var owner: NSWindow?
    private var panel: FloatingPanel?
    private var hovered: String?
    private var pending: DispatchWorkItem?

    init(model: AppModel, owner: NSWindow) {
        self.model = model
        self.owner = owner
    }

    /// A rect means the pointer entered the meeting; nil means it left.
    func hover(_ m: Meeting, at rect: CGRect?) {
        guard let rect else {
            // Leaving one row can arrive after entering the next; ignore it then.
            guard hovered == m.key else { return }
            hovered = nil
            schedule(0.12) { [weak self] in self?.hide() }
            return
        }
        hovered = m.key
        if panel != nil {
            pending?.cancel()
            show(m, rect)
        } else {
            schedule(0.35) { [weak self] in self?.show(m, rect) }
        }
    }

    private func schedule(_ delay: TimeInterval, _ f: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem(block: f)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func show(_ m: Meeting, _ rect: CGRect) {
        guard let owner, owner.isVisible else { return }
        let view = PeekView(meeting: m, now: model.now)
        let host: NSHostingView<PeekView>
        let fresh = panel == nil
        if let existing = panel?.contentView as? NSHostingView<PeekView> {
            host = existing
            host.rootView = view
        } else {
            host = NSHostingView(rootView: view)
            let p = FloatingPanel(level: .popUpMenu, keyable: false)
            p.ignoresMouseEvents = true
            p.contentView = host
            panel = p
        }
        guard let panel else { return }
        let size = host.fittingSize
        let o = owner.frame
        let visible = owner.screen?.visibleFrame ?? o
        // Left of the popover, level with the hovered item; the right side if there's no room.
        var x = o.minX - size.width - 10
        if x < visible.minX + 8 { x = o.maxX + 10 }
        var top = min(o.maxY, o.maxY - rect.minY + 12)
        top = max(top, visible.minY + 8 + size.height)
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
        if fresh {
            panel.orderFront(nil)
            fade([panel], in: true)
            DispatchQueue.main.async { panel.invalidateShadow() }
        }
    }

    func hide() {
        pending?.cancel()
        pending = nil
        hovered = nil
        guard let panel else { return }
        self.panel = nil
        fade([panel], in: false) { panel.orderOut(nil) }
    }
}

// MARK: - Overlay (80% of the screen)

final class ScrimView: NSVisualEffectView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class OverlayController {
    private unowned let model: AppModel
    private var scrim: FloatingPanel?
    private var panel: FloatingPanel?
    private var resignObserver: Any?

    init(model: AppModel) { self.model = model }

    var isVisible: Bool { panel != nil }

    func show(_ m: Meeting) {
        hide(animated: false)
        let screen = screenUnderMouse()
        var area = screen.frame
        area.size.height -= screen.frame.maxY - screen.visibleFrame.maxY // leave the menu bar uncovered

        let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        let scrim = FloatingPanel(level: level, keyable: false)
        let blur = ScrimView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.onClick = { [weak self] in self?.model.minimize() }
        scrim.contentView = blur
        scrim.hasShadow = false
        scrim.setFrame(area, display: false)

        let panel = FloatingPanel(level: level)
        panel.onCancel = { [weak self] in self?.model.minimize() }
        panel.contentView = NSHostingView(rootView: OverlayView(meeting: m).environmentObject(model))
        let inset = NSRect(x: area.minX + area.width * 0.1, y: area.minY + area.height * 0.06,
                           width: area.width * 0.8, height: area.height * 0.88)
        panel.setFrame(inset, display: false)

        scrim.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        fade([scrim, panel], in: true)
        DispatchQueue.main.async { panel.invalidateShadow() }
        self.scrim = scrim
        self.panel = panel

        // Clicking another app, the Dock or the menu bar takes focus away: treat that as minimize.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.minimize() }
        }
    }

    func hide(animated: Bool = true) {
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
        let windows = [scrim, panel].compactMap { $0 }
        scrim = nil
        panel = nil
        guard !windows.isEmpty else { return }
        if animated {
            fade(windows, in: false) { windows.forEach { $0.orderOut(nil) } }
        } else {
            windows.forEach { $0.orderOut(nil) }
        }
    }
}

// MARK: - Mini card

@MainActor
final class MiniCardController {
    static let margin: CGFloat = 10 // room for the ✕ that overhangs the corner
    private unowned let model: AppModel
    private var panel: FloatingPanel?
    private var moveObserver: Any?

    init(model: AppModel) { self.model = model }

    func show() {
        guard panel == nil else { return }
        let panel = FloatingPanel(level: .floating, keyable: false)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: MiniCardView().environmentObject(model))
        panel.contentView = host
        let size = host.fittingSize
        panel.setFrame(NSRect(origin: savedOrigin(for: size) ?? defaultOrigin(for: size), size: size), display: false)
        panel.orderFrontRegardless()
        fade([panel], in: true)
        DispatchQueue.main.async { panel.invalidateShadow() }
        self.panel = panel
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { n in
            guard let w = n.object as? NSWindow else { return }
            UserDefaults.standard.set(NSStringFromPoint(w.frame.origin), forKey: "cardOrigin")
        }
    }

    func hide() {
        if let o = moveObserver { NotificationCenter.default.removeObserver(o) }
        moveObserver = nil
        guard let panel else { return }
        self.panel = nil
        fade([panel], in: false) { panel.orderOut(nil) }
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: v.maxX - size.width - 4, y: v.maxY - size.height - 2)
    }

    private func savedOrigin(for size: NSSize) -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: "cardOrigin") else { return nil }
        let p = NSPointFromString(s)
        let rect = NSRect(origin: p, size: size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(rect) } ? p : nil
    }
}

// MARK: - Menu bar item

@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private(set) lazy var popover = PopoverController(model: model, button: item.button)
    private var bag = Set<AnyCancellable>()
    private var rendered: AppModel.BarState?

    init(model: AppModel) {
        self.model = model
        super.init()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        render()
        model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.render() }.store(in: &bag)
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if case .join(let m) = model.barState, event?.type == .leftMouseUp, event?.modifierFlags.contains(.option) == false {
            model.join(m)
            return
        }
        popover.toggle()
    }

    private func render() {
        let state = model.barState
        guard state != rendered, let button = item.button else { return }
        rendered = state
        button.image = BarArt.image(for: state)
        button.title = ""
    }
}

enum BarArt {
    /// Within this many minutes of the start, the pill turns orange.
    static let soonMinutes = 10
    /// In the last few minutes of a meeting it turns orange too, like the card.
    static let wrapUpMinutes = 3

    private static let orange = NSColor(srgbRed: 0.93, green: 0.42, blue: 0.08, alpha: 1)

    private enum Style: Equatable {
        case white, orange, call(CallKind)
        var fill: NSColor {
            switch self {
            case .white: return NSColor(white: 1, alpha: 0.96)
            case .orange: return BarArt.orange
            case .call(let kind): return kind.nsColor
            }
        }
        var text: NSColor { self == .white ? NSColor(white: 0.1, alpha: 1) : .white }
    }

    private enum Glyph { case calendar, call(CallKind), ring(CGFloat, NSColor?) }

    static func image(for state: AppModel.BarState) -> NSImage? {
        switch state {
        case .idle:
            return calendarTemplate()
        case .later(let m):
            return pill("\(m.shortTitle) at \(Fmt.time(m.start))", .white, .calendar)
        case .soon(let m, let mins):
            return pill("\(m.shortTitle) in \(mins)m", mins <= soonMinutes ? .orange : .white, .ring(CGFloat(mins) / 60, nil))
        case .join(let m):
            let kind = m.link?.kind ?? .other
            return pill("Join \(m.shortTitle)", .call(kind), .call(kind))
        case .during(_, let left, let elapsed):
            let wrapping = left <= wrapUpMinutes
            return pill("\(left)m left", wrapping ? .orange : .white, .ring(CGFloat(elapsed), wrapping ? nil : .systemBlue))
        }
    }

    private static func calendarTemplate() -> NSImage? {
        let img = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Cue")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        img?.isTemplate = true
        return img
    }

    /// A filled capsule with a glyph and text, drawn once per state change.
    private static func pill(_ text: String, _ style: Style, _ glyph: Glyph) -> NSImage {
        let fg = style.text
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: style == .white ? .medium : .semibold),
            .foregroundColor: fg,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let h: CGFloat = 22, glyphSize: CGFloat = 13, pad: CGFloat = 8, gap: CGFloat = 5
        let w = pad + glyphSize + gap + ceil(textSize.width) + pad + 2

        let symbol: NSImage? = {
            let name: String
            switch glyph {
            case .calendar: name = "calendar"
            case .call(let kind):
                guard let symbol = kind.symbol else { return nil }
                name = symbol
            case .ring: return nil
            }
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [fg])))
        }()

        return NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            let capsule = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: h / 2 - 0.5, yRadius: h / 2 - 0.5)
            style.fill.setFill()
            capsule.fill()
            if style == .white {
                NSColor.black.withAlphaComponent(0.12).setStroke()
                capsule.lineWidth = 0.5
                capsule.stroke()
            }
            let g = NSRect(x: pad, y: (h - glyphSize) / 2, width: glyphSize, height: glyphSize)
            if case .ring(let fraction, let tint) = glyph {
                let lw: CGFloat = 2
                let r = g.insetBy(dx: lw / 2, dy: lw / 2)
                let track = NSBezierPath(ovalIn: r)
                track.lineWidth = lw
                fg.withAlphaComponent(0.3).setStroke()
                track.stroke()
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                              startAngle: 90, endAngle: 90 - 360 * max(0.03, min(1, fraction)), clockwise: true)
                arc.lineWidth = lw
                arc.lineCapStyle = .round
                (tint ?? fg).setStroke()
                arc.stroke()
            } else if case .call(let kind) = glyph, let path = kind.glyph, let ctx = NSGraphicsContext.current?.cgContext {
                // The mark is drawn on a 24-point grid with y down; flip it into the pill.
                let side: CGFloat = 14
                ctx.saveGState()
                ctx.translateBy(x: g.midX - side / 2, y: g.midY + side / 2)
                ctx.scaleBy(x: side / 24, y: -side / 24)
                ctx.addPath(path.cgPath)
                ctx.setFillColor(fg.cgColor)
                ctx.fillPath(using: .evenOdd)
                ctx.restoreGState()
            } else if let symbol {
                let sz = symbol.size
                symbol.draw(in: NSRect(x: g.midX - sz.width / 2, y: g.midY - sz.height / 2, width: sz.width, height: sz.height))
            }
            (text as NSString).draw(at: NSPoint(x: pad + glyphSize + gap, y: (h - textSize.height) / 2), withAttributes: attrs)
            return true
        }
    }
}
