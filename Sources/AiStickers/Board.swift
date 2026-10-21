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
    var addingTag: UUID?  // card whose tag picker is open
}

/// Floating, non-activating, transparent: clicks pass through everything SwiftUI doesn't draw.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }  // the new-tag text field needs keyboard input

    convenience init(_ frame: NSRect, _ content: some View) {
        self.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false  // SwiftUI draws the shadows
        contentView = NSHostingView(rootView: content)
    }
}

/// Room around a pinned sticker for its shadow and for growing on hover.
let pinMargin: CGFloat = 24
private let pinWindow = NSSize(width: 280 + 2 * pinMargin, height: 520 + 2 * pinMargin)
private let panelWidth: CGFloat = 340
private let panelInset: CGFloat = 12
/// The collapsed sticker that must stay on screen; the rest of its window is margin and room to grow.
private let pinCard = CGSize(width: 220, height: 100)
private let toastSize = NSSize(width: 360, height: 80)

/// The edge tab, the ideas panel it opens, and one window per sticker pinned to the desktop.
@MainActor
final class Board {
    let store: Store
    let state = BoardState()
    private var tab: Panel!
    private var panel: Panel!
    private var toast: Panel!
    private var pinned: [UUID: (window: Panel, observer: NSObjectProtocol)] = [:]
    private var ghost: Panel?

    init(store: Store) { self.store = store }

    /// The menu-bar screen: the tab stays put instead of following whichever screen has focus.
    private var screen: NSRect { NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }

    /// The panel strip from the screen edge to the card's right side; dropping here does not pin.
    private var panelRect: NSRect {
        NSRect(x: panel.frame.minX, y: panel.frame.minY, width: panelInset + panelWidth, height: panel.frame.height)
    }

    func start() {
        tab = Panel(.zero, EdgeTab(store: store, open: { [unowned self] in setOpen(true) }))
        panel = Panel(.zero, PanelView(store: store, state: state, board: self))
        toast = Panel(.zero, UndoToast(store: store))
        toast.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        layout()
        tab.orderFrontRegardless()
        toast.orderFrontRegardless()  // empty and click-through until something is deleted
        syncPinned()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    /// Monitors and the Dock change at runtime: re-fit the edge windows and pull pinned stickers back on screen.
    private func layout() {
        let vf = screen
        tab.setFrame(NSRect(x: vf.minX, y: vf.maxY - 300, width: 64, height: 172), display: true)
        panel.setFrame(NSRect(x: vf.minX, y: vf.minY, width: panelInset + panelWidth + 40, height: vf.height), display: true)
        toast.setFrame(NSRect(x: vf.midX - toastSize.width / 2, y: vf.minY + 24, width: toastSize.width, height: toastSize.height), display: true)
        for (_, p) in pinned {
            let w = p.window
            let at = onScreen(left: w.frame.minX + pinMargin, top: w.frame.maxY - pinMargin)
            if at != w.frame.origin { w.setFrameOrigin(at) }  // didMove saves the new spot
        }
    }

    /// Window origin for a pinned sticker whose card corner is at (left, top), kept on the nearest screen.
    private func onScreen(left: Double, top: Double) -> NSPoint {
        let p = clampTopLeft(CGPoint(x: left, y: top), card: pinCard, screens: NSScreen.screens.map(\.visibleFrame))
        return NSPoint(x: p.x - pinMargin, y: p.y + pinMargin - pinWindow.height)
    }

    func setOpen(_ open: Bool) {
        state.open = open
        if open {
            panel.orderFrontRegardless()
            tab.orderOut(nil)
        } else {
            state.hovered = nil
            state.addingTag = nil
            ghost?.close()  // a drag cancelled mid-way never reaches dragEnded
            ghost = nil
            panel.orderOut(nil)
            tab.orderFrontRegardless()
        }
    }

    /// Leaving the panel while dragging a card out is the point of the drag, not a reason to close.
    func mouseLeftPanel() {
        if !state.locked && ghost == nil { setOpen(false) }
    }

    func syncPinned() {
        let ids = Set(store.stickers.filter(\.pinned).map(\.id))
        for (id, p) in pinned where !ids.contains(id) {
            NotificationCenter.default.removeObserver(p.observer)
            pinned[id] = nil
            // Unpin/delete come from a button inside this window: close it after that event finishes.
            DispatchQueue.main.async { p.window.close() }
        }
        for s in store.stickers where s.pinned && pinned[s.id] == nil {
            let w = Panel(NSRect(origin: .zero, size: pinWindow), PinnedView(id: s.id, store: store))
            w.isMovableByWindowBackground = true
            // Not saved back: if the monitor returns on the next launch, so does the sticker.
            w.setFrameOrigin(onScreen(left: s.left ?? 400, top: s.top ?? 700))
            w.orderFrontRegardless()
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { [weak self, weak w] _ in
                MainActor.assumeIsolated {
                    guard let w else { return }
                    self?.store.place(s.id, left: w.frame.minX + pinMargin, top: w.frame.maxY - pinMargin)
                }
            }
            pinned[s.id] = (w, observer)
        }
    }

    // Dragging a card: a preview follows the mouse; dropped outside the panel, the sticker gets pinned there.
    // The grab point sits near the sticker's top-left corner.
    func dragChanged(_ id: UUID) {
        if state.hovered != nil { state.hovered = nil }  // @Observable notifies even on equal writes
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

    /// The system cancelled the drag (onEnded never comes): drop the preview and close if the mouse already left.
    func dragCancelled() {
        guard let g = ghost else { return }
        g.close()
        ghost = nil
        // The window is wider and taller than the card (shadow room); only the card and the edge strip count as inside.
        if state.open && !panelRect.insetBy(dx: 0, dy: 24).contains(NSEvent.mouseLocation) { mouseLeftPanel() }
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
