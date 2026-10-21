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
    var dragging = false
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

/// The edge tab, the ideas panel it opens, and one window per sticker pinned to the desktop.
@MainActor
final class Board {
    let store: Store
    let state = BoardState()
    private var tab: Panel!
    private var panel: Panel!
    private var pinned: [UUID: Panel] = [:]
    private var ghost: Panel?

    init(store: Store) { self.store = store }

    private var screen: NSRect { NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }

    /// The visible panel card inside its (wider, transparent) window.
    private var panelRect: NSRect {
        NSRect(x: screen.minX + panelInset, y: screen.minY, width: panelWidth, height: screen.height)
    }

    func start() {
        let vf = screen
        tab = Panel(NSRect(x: vf.minX, y: vf.maxY - 300, width: 64, height: 172),
                    EdgeTab(store: store, open: { [unowned self] in setOpen(true) }))
        panel = Panel(NSRect(x: vf.minX, y: vf.minY, width: panelInset + panelWidth + 40, height: vf.height),
                      PanelView(store: store, state: state, board: self))
        tab.orderFrontRegardless()
        syncPinned()
    }

    func setOpen(_ open: Bool) {
        state.open = open
        if open {
            panel.orderFrontRegardless()
            tab.orderOut(nil)
        } else {
            state.hovered = nil
            state.addingTag = nil
            panel.orderOut(nil)
            tab.orderFrontRegardless()
        }
    }

    func mouseLeftPanel() {
        if !state.locked && !state.dragging { setOpen(false) }
    }

    func syncPinned() {
        let ids = Set(store.stickers.filter(\.pinned).map(\.id))
        for (id, w) in pinned where !ids.contains(id) {
            w.close()
            pinned[id] = nil
        }
        for s in store.stickers where s.pinned && pinned[s.id] == nil {
            let w = Panel(NSRect(origin: .zero, size: pinWindow), PinnedView(id: s.id, store: store))
            w.isMovableByWindowBackground = true
            w.setFrameTopLeftPoint(NSPoint(x: (s.left ?? 400) - pinMargin, y: (s.top ?? 700) + pinMargin))
            w.orderFrontRegardless()
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.store.place(s.id, left: w.frame.minX + pinMargin, top: w.frame.maxY - pinMargin)
                }
            }
            pinned[s.id] = w
        }
    }

    // Dragging a card: a preview follows the mouse; dropped outside the panel, the sticker gets pinned there.
    // The grab point sits near the sticker's top-left corner.
    func dragChanged(_ id: UUID) {
        state.dragging = true
        state.hovered = nil
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

    func dragEnded(_ id: UUID) {
        ghost?.close()
        ghost = nil
        state.dragging = false
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
