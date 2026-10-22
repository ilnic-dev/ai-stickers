import AppKit
import SwiftUI

/// UI-only state: nothing here is persisted.
@MainActor @Observable
final class BoardState {
    var open = false
    var locked = false
    var filter: Set<String> = []
    var showLater = false
    var hovered: UUID?
    var frozenOrder: [UUID]?  // the panel's order while a card is open, see keepingOrder
    var addingTag: UUID?  // card whose tag picker is open
}

/// Floating, non-activating, transparent: clicks pass through everything SwiftUI doesn't draw.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }  // the new-tag text field needs keyboard input

    /// Panels never activate the app, so a click on one that isn't key would be spent on making it key
    /// (in any subview: scroll view, card, button). Become key first and let the click through.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown && !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }

    convenience init(_ frame: NSRect, _ content: some View) {
        self.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false  // SwiftUI draws the shadows
        contentView = FirstClickHostingView(rootView: content)
    }
}

/// The panels never activate the app, so without this the first click on them is spent making
/// the window key and a card can't be grabbed until the second try.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Room around a pinned sticker for its shadow and for growing on hover.
let pinMargin: CGFloat = 24
private let pinWindow = NSSize(width: 280 + 2 * pinMargin, height: 700 + 2 * pinMargin)  // room for the open sticker's pickers
private let panelWidth: CGFloat = 340
let panelMargin: CGFloat = 24        // shadow room around the panel card, inside its window
let panelBottom: CGFloat = 48        // the shadow falls downward (radius 25, y 18)
private let panelMaxHeight: CGFloat = 640
/// The collapsed sticker that must stay on screen; the rest of its window is margin and room to grow.
private let pinCard = CGSize(width: 220, height: 100)
private let toastSize = NSSize(width: 360, height: 80)

/// The ideas panel dropping down from the menu bar icon, and one window per sticker pinned to the desktop.
@MainActor
final class Board {
    let store: Store
    let state = BoardState()
    private var panel: Panel!
    private var toast: Panel!
    private var pinned: [UUID: Panel] = [:]
    private var ghost: Panel?

    /// The menu bar icon's frame on screen; the panel opens under it.
    private let anchor: () -> NSRect?

    init(store: Store, anchor: @escaping () -> NSRect?) {
        self.store = store
        self.anchor = anchor
    }

    /// The menu-bar screen.
    private var screen: NSRect { NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }

    /// The panel card inside its window; dropping a card here does not pin it.
    private var panelRect: NSRect {
        NSRect(x: panel.frame.minX + panelMargin, y: panel.frame.minY + panelBottom,
               width: panelWidth, height: panel.frame.height - panelBottom)
    }

    func start() {
        panel = Panel(.zero, PanelView(store: store, state: state, board: self))
        toast = Panel(.zero, UndoToast(store: store))
        toast.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        layout()
        toast.orderFrontRegardless()  // empty and click-through until something is deleted
        syncPinned()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        // A card that leaves the list mid-drag (filtered, deleted) takes its gesture with it, and neither
        // onEnded nor the GestureState reset fires. The mouse-up still reaches the app: clear the ghost then.
        // Safe in any order: dragEnded pins from the mouse position and never reads `ghost`.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            DispatchQueue.main.async { self?.dragCancelled() }
            return event
        }
        // Like a menu: a click in another app or on the desktop closes the panel, unless it's pinned open.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.state.open, !self.state.locked, self.ghost == nil else { return }
                self.setOpen(false)
            }
        }
        // Esc closes it once the panel has been clicked (it only gets keys as the key window).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let closed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.state.open else { return false }
                if self.state.addingTag != nil {
                    self.state.addingTag = nil  // first Esc just closes the tag picker
                    return true
                }
                self.setOpen(false)
                return true
            }
            return closed ? nil : event
        }
    }

    private var toastFor: UUID?

    /// Store changed: sync pinned windows; on a new deletion, put the undo toast on the screen with
    /// the mouse, which is where the sticker was. Other changes leave a visible toast where it is.
    func storeChanged() {
        syncPinned()
        if let id = store.removed?.sticker.id, id != toastFor {
            toastFor = id
            placeToast()
        }
    }

    private func placeToast() {
        let mouse = NSEvent.mouseLocation
        let vf = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? screen
        toast.setFrame(NSRect(x: vf.midX - toastSize.width / 2, y: vf.minY + 24, width: toastSize.width, height: toastSize.height), display: true)
    }

    /// Monitors and the Dock change at runtime: re-place the panel and the toast, pull pinned stickers back on screen.
    private func layout() {
        if state.open { positionPanel() }
        placeToast()
        for id in pinned.keys { pinnedMoved(id) }
    }

    /// A pinned sticker was let go (or the screens changed): keep it on screen and save where it is.
    func pinnedMoved(_ id: UUID) {
        guard let w = pinned[id] else { return }
        let at = onScreen(left: w.frame.minX + pinMargin, top: w.frame.maxY - pinMargin)
        if at != w.frame.origin { w.setFrameOrigin(at) }
        store.place(id, left: w.frame.minX + pinMargin, top: w.frame.maxY - pinMargin)
    }

    /// Window origin for a pinned sticker whose card corner is at (left, top), kept on the nearest screen.
    private func onScreen(left: Double, top: Double) -> NSPoint {
        let p = clampTopLeft(CGPoint(x: left, y: top), card: pinCard, screens: NSScreen.screens.map(\.visibleFrame))
        return NSPoint(x: p.x - pinMargin, y: p.y + pinMargin - pinWindow.height)
    }

    func toggle() { setOpen(!state.open) }

    func setOpen(_ open: Bool) {
        state.open = open
        if open {
            positionPanel()
            panel.orderFrontRegardless()
        } else {
            state.hovered = nil
            state.frozenOrder = nil
            state.addingTag = nil
            ghost?.close()  // a drag cancelled mid-way never reaches dragEnded
            ghost = nil
            panel.orderOut(nil)
        }
    }

    /// Hangs the card right under the menu bar, centred on the icon and kept on that screen.
    private func positionPanel() {
        let icon = anchor() ?? NSRect(x: screen.maxX - 120, y: screen.maxY, width: 24, height: 22)
        let vf = (NSScreen.screens.first { $0.frame.intersects(icon) } ?? NSScreen.main)?.visibleFrame ?? screen
        let height = min(panelMaxHeight, vf.height - 12)
        let x = min(max(icon.midX - panelWidth / 2, vf.minX + 6), vf.maxX - panelWidth - 6)
        let top = vf.maxY - 6
        panel.setFrame(NSRect(x: x - panelMargin, y: top - height - panelBottom,
                              width: panelWidth + 2 * panelMargin, height: height + panelBottom), display: true)
    }

    func syncPinned() {
        let ids = Set(store.stickers.filter(\.pinned).map(\.id))
        for (id, w) in pinned where !ids.contains(id) {
            pinned[id] = nil
            // Unpin/delete come from a button inside this window: close it after that event finishes.
            DispatchQueue.main.async { w.close() }
        }
        for s in store.stickers where s.pinned && pinned[s.id] == nil {
            let w = Panel(NSRect(origin: .zero, size: pinWindow),
                          PinnedView(id: s.id, store: store, onMoved: { [weak self] in self?.pinnedMoved(s.id) }))
            // Not saved back: if the monitor returns on the next launch, so does the sticker.
            w.setFrameOrigin(onScreen(left: s.left ?? 400, top: s.top ?? 700))
            w.collectionBehavior = Board.pinnedBehavior
            w.orderFrontRegardless()  // a window that doesn't join all Spaces stays on the current one
            pinned[s.id] = w
        }
    }

    // MARK: - Desktops (Spaces)

    private static let allSpacesKey = "stickersOnAllSpaces"

    /// Off by default: a pinned sticker stays on the desktop where it was put. macOS has no public way to
    /// put a window on a given desktop, so after a relaunch they all start on the current one.
    static var stickersOnAllSpaces: Bool {
        get { UserDefaults.standard.bool(forKey: allSpacesKey) }
        set { UserDefaults.standard.set(newValue, forKey: allSpacesKey) }
    }

    private static var pinnedBehavior: NSWindow.CollectionBehavior {
        stickersOnAllSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
    }

    func setStickersOnAllSpaces(_ on: Bool) {
        Board.stickersOnAllSpaces = on
        for w in pinned.values { w.collectionBehavior = Board.pinnedBehavior }
    }

    // Dragging a card: a preview follows the mouse; dropped outside the panel, the sticker gets pinned there.
    // The grab point sits near the sticker's top-left corner.
    func dragChanged(_ id: UUID) {
        if state.hovered != nil { state.hovered = nil }  // @Observable notifies even on equal writes
        if state.frozenOrder != nil { state.frozenOrder = nil }
        if ghost == nil {
            let g = Panel(NSRect(origin: .zero, size: pinWindow), PinnedView(id: id, store: store, preview: true))
            g.ignoresMouseEvents = true
            g.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            g.alphaValue = 0.85
            g.orderFrontRegardless()
            ghost = g
        }
        let p = NSEvent.mouseLocation
        ghost?.setFrameTopLeftPoint(NSPoint(x: p.x - 24 - pinMargin, y: p.y + 16 + pinMargin))
    }

    /// The system cancelled the drag (onEnded never comes): drop the preview.
    func dragCancelled() {
        guard let g = ghost else { return }
        g.close()
        ghost = nil
    }

    func dragEnded(_ id: UUID) {
        ghost?.close()
        ghost = nil
        let p = NSEvent.mouseLocation
        guard !panelRect.contains(p) else { return }
        store.update(id) {
            $0.pinned = true
            $0.left = p.x - 24
            $0.top = p.y + 16
        }
        if !state.locked { setOpen(false) }
    }
}
