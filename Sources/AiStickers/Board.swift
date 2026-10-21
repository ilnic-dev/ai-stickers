import AppKit
import SwiftUI

/// One floating, draggable panel per sticker. New stickers line up along the left edge of the screen.
@MainActor
final class Board {
    private let store: Store
    private var panels: [UUID: (panel: NSPanel, view: NSHostingView<StickerView>)] = [:]
    private var expanded: Set<UUID> = []

    init(store: Store) { self.store = store }

    func sync() {
        for (id, p) in panels where !store.stickers.contains(where: { $0.id == id }) {
            p.panel.close()
            panels[id] = nil
        }
        for s in store.stickers where panels[s.id] == nil { open(s) }
    }

    private func open(_ s: Sticker) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let view = NSHostingView(rootView: render(s))
        panel.contentView = view
        panels[s.id] = (panel, view)

        let (left, top) = s.left.flatMap { l in s.top.map { (l, $0) } } ?? slot(for: panels.count - 1)
        resize(s.id, left: left, top: top)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.place(s.id, left: panel.frame.minX, top: panel.frame.maxY)
            }
        }
    }

    // ponytail: slots ignore stickers that were dragged away, so a new one may land on an old one.
    private func slot(for index: Int) -> (Double, Double) {
        let vf = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let perColumn = max(1, Int((vf.height - 16) / 84))
        return (vf.minX + 12 + Double(index / perColumn) * 196, vf.maxY - 12 - Double(index % perColumn) * 84)
    }

    private func render(_ s: Sticker) -> StickerView {
        StickerView(sticker: s, expanded: expanded.contains(s.id),
                    toggle: { [weak self] in self?.toggle(s.id) },
                    delete: { [weak self] in self?.store.remove(s.id) })
    }

    private func toggle(_ id: UUID) {
        guard let p = panels[id], let s = store.stickers.first(where: { $0.id == id }) else { return }
        if expanded.remove(id) == nil { expanded.insert(id) }
        p.view.rootView = render(s)
        resize(id, left: p.panel.frame.minX, top: p.panel.frame.maxY)
    }

    /// Grows downward from a fixed top-left corner, kept on screen.
    private func resize(_ id: UUID, left: Double, top: Double) {
        guard let p = panels[id] else { return }
        let size = p.view.fittingSize
        let vf = (p.panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let y = max(vf.minY, top - size.height)
        p.panel.setFrame(NSRect(x: left, y: y, width: size.width, height: size.height), display: true)
    }
}

struct StickerView: View {
    let sticker: Sticker
    let expanded: Bool
    let toggle: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(sticker.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if expanded {
                    Button(action: delete) { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .help("Удалить стикер")
                }
            }
            if expanded {
                Text(sticker.summary)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(sticker.todo, id: \.self) { item in
                    Text("☐ \(item)")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(sticker.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .opacity(0.6)
            }
        }
        .padding(10)
        .frame(width: expanded ? 300 : 180, alignment: .leading)
        .foregroundStyle(.black)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 1, green: 0.92, blue: 0.55)))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}
