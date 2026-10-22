import AppKit
import SwiftUI

enum Palette {
    static let sticky = Color(hex: 0xFFE9A8)
    static let ink = Color(hex: 0x2A2214)
    static let inkSoft = Color(hex: 0x4A3C17)
    static let meta = Color(hex: 0x6A5622)
    static let panel = Color(hex: 0xF6F3EA)
    static let panelInk = Color(hex: 0x1F1B14)
    static let muted = Color(hex: 0x6B6457)
    private static let tags: [UInt32] = [0x2563EB, 0xC2410C, 0x15803D, 0x7C3AED, 0x0E7490, 0xBE185D, 0xA16207, 0x4F46E5]

    /// Alphabetical position among all tags: distinct colors for up to 8 tags.
    // ponytail: a new tag can shift other tags' colors; persist colors if that gets annoying.
    static func tag(_ name: String, in vocabulary: [String]) -> Color {
        let i = vocabulary.sorted().firstIndex(of: name) ?? 0
        return Color(hex: tags[i % tags.count])
    }

    /// The whole card takes its status color, so a list (or the desktop) reads at a glance.
    static func sticky(_ status: StickerStatus) -> Color {
        switch status {
        case .new: Color(hex: 0xFFE9A8)
        case .inProgress: Color(hex: 0xCFE6FF)
        case .onHold: Color(hex: 0xFFD6B0)
        case .postponed: Color(hex: 0xE5E1D8)
        }
    }

    static func flag(_ priority: Priority) -> Color {
        switch priority {
        case .none, .low: Color(hex: 0x6B7280)
        case .medium: Color(hex: 0xB45309)
        case .high: Color(hex: 0xDC2626)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

private let timeFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
func when(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return tr("сегодня", "today") + ", " + timeFormat.string(from: date) }
    if Calendar.current.isDateInYesterday(date) { return tr("вчера", "yesterday") + ", " + timeFormat.string(from: date) }
    return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: tr("ru_RU", "en_US"))))
}

// MARK: - Panel

struct PanelView: View {
    let store: Store
    let state: BoardState
    let board: Board

    var body: some View {
        let inPanel = store.stickers.filter { !$0.pinned }
        let active = store.stickers.filter { !$0.isPostponed }  // pinned ones too: they are still open ideas
        let list = panelStickers(store.stickers, filter: state.filter, showPostponed: state.showLater)
        let laterCount = inPanel.filter(\.isPostponed).count
        let counts = Dictionary(inPanel.flatMap(\.tags).map { ($0, 1) }, uniquingKeysWith: +)

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Идеи", "Ideas")).font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.panelInk)
                    Text(tr("актуально: ", "open: ") + "\(active.count) · " + tr("задач: ", "todos: ") + "\(active.reduce(0) { $0 + $1.openTodos })")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { state.locked.toggle() } label: {
                    Image(systemName: "pin")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(state.locked ? Palette.panel : Palette.muted)
                        .frame(width: 36, height: 36)
                        .background(state.locked ? Palette.panelInk : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state.locked ? tr("Открепить панель", "Unpin the panel") : tr("Закрепить панель открытой", "Keep the panel open"))
                .accessibilityLabel(state.locked ? tr("Открепить панель", "Unpin the panel") : tr("Закрепить панель открытой", "Keep the panel open"))
                Button { state.locked = false; board.setOpen(false) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Закрыть", "Close"))
            }
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 10, trailing: 16))

            FlowLayout(spacing: 6) {
                FilterChip(label: tr("Все", "All"), count: nil, color: nil, on: state.filter.isEmpty) { state.filter = [] }
                // Selected tags stay visible even when no sticker has them any more, so they can be unselected.
                let shown = store.vocabulary.filter { counts[$0, default: 0] > 0 } + state.filter.subtracting(Set(inPanel.flatMap(\.tags))).sorted()
                ForEach(shown, id: \.self) { t in
                    FilterChip(label: t, count: counts[t], color: Palette.tag(t, in: store.vocabulary), on: state.filter.contains(t)) {
                        if state.filter.contains(t) { state.filter.remove(t) } else { state.filter.insert(t) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 8) {
                    let shown = keepingOrder(list, state.frozenOrder)
                    ForEach(shown) { s in CardView(sticker: s, store: store, state: state, board: board, order: shown.map(\.id)) }
                    if inPanel.isEmpty {
                        Text(tr("Пока пусто. Напиши мысль боту в Telegram.", "Nothing yet. Send a thought to the Telegram bot.")).emptyNote()
                    } else if list.isEmpty {
                        Text(tr("Нет идей с этими тегами", "No ideas with these tags")).emptyNote()
                    }
                    if laterCount > 0 {
                        Button { state.showLater.toggle() } label: {
                            Text(state.showLater ? tr("Скрыть отложенные", "Hide postponed") : tr("Показать отложенные", "Show postponed") + " · \(laterCount)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color(hex: 0x4A443A))
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(Palette.panelInk.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            HStack(spacing: 8) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").accessibilityHidden(true)
                Text(tr("Перетащи стикер на стол, чтобы закрепить", "Drag a sticker onto the desktop to pin it"))
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 10, leading: 18, bottom: 14, trailing: 18))
            .overlay(alignment: .top) { Rectangle().fill(Palette.panelInk.opacity(0.08)).frame(height: 1) }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.panel).shadow(color: .black.opacity(0.35), radius: 25, y: 18))
        .padding(.horizontal, panelMargin)
        .padding(.bottom, panelBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct FilterChip: View {
    let label: String
    let count: Int?
    let color: Color?
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 8, height: 8) }
                Text(label)
                if let count { Text("\(count)").monospacedDigit().opacity(0.7) }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(on ? Palette.panel : Palette.ink)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(on ? Palette.panelInk : .white, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.panelInk.opacity(on ? 1 : 0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Card in the panel

struct CardView: View {
    let sticker: Sticker
    let store: Store
    let state: BoardState
    let board: Board
    /// The list's order when this card was opened; frozen while it's open.
    let order: [UUID]
    @GestureState private var dragging = false

    var body: some View {
        let expanded = state.hovered == sticker.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                if sticker.priority != .none { FlagIcon(priority: sticker.priority).padding(.top, 3) }
                Text(sticker.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if expanded {
                    HStack(spacing: 0) {
                        CopyButton(text: clipboardText(sticker))
                        IconButton("trash", label: tr("Удалить", "Delete")) { store.remove(sticker.id) }
                    }
                    .padding(.top, -4)
                    .padding(.trailing, -4)
                }
            }
            if expanded {
                Text(sticker.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                if !sticker.todo.isEmpty { TodoList(sticker: sticker, store: store).padding(.top, 10) }
                StatusPriorityPicker(sticker: sticker, store: store).padding(.top, 12)
                TagEditor(sticker: sticker, store: store, state: state).padding(.top, 10)
            }
            MetaRow(sticker: sticker, store: store, showTags: !expanded).padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .foregroundStyle(Palette.ink)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.sticky(sticker.status))
            .shadow(color: Color(hex: 0x3C2D0A).opacity(expanded ? 0.18 : 0.10), radius: expanded ? 9 : 1, y: expanded ? 6 : 1))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0x785A14).opacity(0.16)))
        .opacity(sticker.isPostponed ? 0.75 : 1)
        .animation(.easeOut(duration: 0.16), value: sticker.status)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                if state.frozenOrder == nil { state.frozenOrder = order }
                state.hovered = sticker.id
            } else if state.hovered == sticker.id {
                state.hovered = nil
                state.frozenOrder = nil
                state.addingTag = nil
            }
        }
        .gesture(DragGesture(minimumDistance: 8)
            .updating($dragging) { _, d, _ in d = true }
            .onChanged { _ in board.dragChanged(sticker.id) }
            .onEnded { _ in board.dragEnded(sticker.id) })
        // GestureState resets on cancel too; after a normal drop dragEnded has already cleared the ghost.
        .onChange(of: dragging) { if !dragging { board.dragCancelled() } }
        .animation(.easeOut(duration: 0.16), value: expanded)
    }
}

struct TodoList: View {
    let sticker: Sticker
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(sticker.todo.enumerated()), id: \.offset) { i, text in
                let done = sticker.done.contains(i)
                Button {
                    store.update(sticker.id) { if done { $0.done.remove(i) } else { $0.done.insert(i) } }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(Palette.meta)
                        Text(text)
                            .strikethrough(done)
                            .foregroundStyle(done ? Palette.meta : Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 13))
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(done ? .isSelected : [])
            }
        }
    }
}

struct TagEditor: View {
    let sticker: Sticker
    let store: Store
    let state: BoardState
    @State private var newTag = ""

    var body: some View {
        let open = state.addingTag == sticker.id
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(sticker.tags, id: \.self) { t in
                    Button { store.update(sticker.id) { $0.tags.removeAll { $0 == t } } } label: {
                        HStack(spacing: 5) {
                            TagDot(name: t, store: store)
                            Text(t)
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.meta)
                        }
                        .chip(fill: .white.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("Убрать тег ", "Remove tag ") + t)
                }
                Button { state.addingTag = open ? nil : sticker.id } label: {
                    Text(tr("+ тег", "+ tag"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.meta)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .overlay(Capsule().strokeBorder(Palette.meta.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
                .buttonStyle(.plain)
            }
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    FlowLayout(spacing: 6) {
                        ForEach(store.vocabulary.filter { !sticker.tags.contains($0) }, id: \.self) { t in
                            Button { add(t) } label: {
                                HStack(spacing: 5) { TagDot(name: t, store: store); Text(t) }.chip(fill: Palette.panel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField(tr("новый тег", "new tag"), text: $newTag)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(Palette.panel, in: Capsule())
                        .onSubmit { add(normalizeTag(newTag)); newTag = "" }
                }
                .padding(6)
                .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func add(_ tag: String) {
        guard !tag.isEmpty, !sticker.tags.contains(tag) else { return }
        // "позже"/"later" is the postponed status, as in a #hashtag, not a tag.
        store.update(sticker.id) { if tag == laterTag { $0.status = .postponed } else { $0.tags.append(tag) } }
        state.addingTag = nil
    }
}

struct MetaRow: View {
    let sticker: Sticker
    let store: Store
    let showTags: Bool

    var body: some View {
        FlowLayout(spacing: 8) {
            if sticker.status != .new { Text(sticker.status.label).fontWeight(.semibold) }
            Text(when(sticker.created))
            if !sticker.todo.isEmpty {
                Text(sticker.openTodos == 0 ? tr("всё сделано", "all done") : "\(sticker.openTodos) " + tr("из", "of") + " \(sticker.todo.count)")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Palette.meta.opacity(0.12), in: Capsule())
            }
            if showTags {
                ForEach(sticker.tags, id: \.self) { t in
                    HStack(spacing: 4) { TagDot(name: t, store: store); Text(t) }
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.meta)
    }
}

// MARK: - Sticker pinned to the desktop

struct PinnedView: View {
    let id: UUID
    let store: Store
    var preview = false
    var onMoved: () -> Void = {}
    @State private var hovered = false
    @State private var moving = false

    var body: some View {
        if let s = store.stickers.first(where: { $0.id == id }) {
            // Stays open while being moved, or it would shrink and slide the handle out from under the cursor.
            let expanded = (hovered || moving) && !preview
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    if s.priority != .none { FlagIcon(priority: s.priority).padding(.top, 4) }
                    Text(s.title)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if expanded {
                        CopyButton(text: clipboardText(s))
                        IconButton("pin.slash", label: tr("Вернуть в панель", "Back to the panel")) { store.update(id) { $0.pinned = false } }
                        IconButton("trash", label: tr("Удалить", "Delete")) { store.remove(id) }
                    }
                    MoveHandle(moving: $moving, onMoved: onMoved)
                }
                Text(s.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.inkSoft)
                    .lineLimit(expanded ? nil : 2)
                    .padding(.top, 6)
                if expanded && !s.todo.isEmpty { TodoList(sticker: s, store: store).padding(.top, 10) }
                if expanded { StatusPriorityPicker(sticker: s, store: store).padding(.top, 12) }
                MetaRow(sticker: s, store: store, showTags: true).padding(.top, 8)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .frame(width: expanded ? 280 : 220, alignment: .leading)
            .foregroundStyle(Palette.ink)
            .background(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4, bottomTrailingRadius: 14, topTrailingRadius: 4)
                .fill(Palette.sticky(s.status)).shadow(color: .black.opacity(0.32), radius: 14, y: 10))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.16), value: expanded)
            .padding(pinMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Undo after delete

/// «Отменить» for 5 seconds after a sticker is deleted, from the panel or from the desktop.
struct UndoToast: View {
    let store: Store

    var body: some View {
        // The frame stays outside the `if`: NSHostingView sizes the window to its content, and empty content is 0×0.
        ZStack {
            if let r = store.removed { toast(r.sticker) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toast(_ s: Sticker) -> some View {
        HStack(spacing: 12) {
            Text(tr("Стикер «\(s.title)» удалён", "Deleted “\(s.title)”"))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(tr("Отменить", "Undo")) { store.undoRemove() }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(Palette.sticky)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .font(.system(size: 13))
        .foregroundStyle(Palette.panel)
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(Palette.panelInk, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .padding(.horizontal, 12)
        .task(id: s.id) {
            guard (try? await Task.sleep(for: .seconds(5))) != nil else { return }
            store.forgetRemoved(s.id)
        }
    }
}

// MARK: - Small pieces

/// Told apart by shape as well as color: outline (low), filled (medium), filled with "!" (high).
struct FlagIcon: View {
    let priority: Priority
    var color: Color?
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: priority == .low ? "flag" : "flag.fill")
            if priority == .high { Text("!").fontWeight(.heavy) }
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(color ?? Palette.flag(priority))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Приоритет: ", "Priority: ") + priority.label.lowercased())
    }
}

/// Two rows of chips on an open card or pinned sticker: its status (each chip shows that status's color)
/// and its priority.
struct StatusPriorityPicker: View {
    let sticker: Sticker
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Статус", "Status")).pickerTitle()
            FlowLayout(spacing: 6) {
                ForEach(StickerStatus.allCases, id: \.self) { status in
                    let on = sticker.status == status
                    Button { store.update(sticker.id) { $0.status = status } } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Palette.sticky(status))
                                .overlay(Circle().strokeBorder(Palette.ink.opacity(0.25)))
                                .frame(width: 12, height: 12)
                            Text(status.label)
                        }
                        .pickerChip(on: on)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text(tr("Приоритет", "Priority")).pickerTitle().padding(.top, 4)
            FlowLayout(spacing: 6) {
                ForEach(Priority.allCases, id: \.self) { priority in
                    let on = sticker.priority == priority
                    Button { store.update(sticker.id) { $0.priority = priority } } label: {
                        HStack(spacing: 5) {
                            if priority != .none {
                                FlagIcon(priority: priority, color: on ? Palette.panel : nil, size: 10).accessibilityHidden(true)  // the chip says it
                            }
                            Text(priority.label)
                        }
                        .pickerChip(on: on)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }
}

/// Copies the sticker as text; the icon turns into a check for a moment so the click is visibly done.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        IconButton(copied ? "checkmark" : "doc.on.doc", label: copied ? tr("Скопировано", "Copied") : tr("Скопировать", "Copy")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }
}

/// Grab it to move the sticker's window anywhere on screen.
struct MoveHandle: View {
    @Binding var moving: Bool
    let onMoved: () -> Void

    var body: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.meta)
            .frame(width: 28, height: 28)
            .background(Palette.meta.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(WindowDragArea(moving: $moving, onMoved: onMoved))
            .help(tr("Перетащить", "Move"))
            .accessibilityLabel(tr("Перетащить стикер", "Move the sticker"))
    }
}

/// Moves its window with the mouse. Tracked by hand rather than with performDrag, which drops the
/// hover state mid-drag; the position is saved once, on release.
struct WindowDragArea: NSViewRepresentable {
    @Binding var moving: Bool
    let onMoved: () -> Void

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
        view.onMoving = { moving = $0 }
        view.onMoved = onMoved
    }

    final class DragView: NSView {
        var onMoving: (Bool) -> Void = { _ in }
        var onMoved: () -> Void = {}
        private var start: (mouse: NSPoint, origin: NSPoint)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }  // we move it ourselves
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            start = (NSEvent.mouseLocation, window.frame.origin)
            onMoving(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let start else { return }
            let p = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: start.origin.x + p.x - start.mouse.x, y: start.origin.y + p.y - start.mouse.y))
        }

        override func mouseUp(with event: NSEvent) {
            start = nil
            onMoving(false)
            onMoved()
        }
    }
}

struct TagDot: View {
    let name: String
    let store: Store
    var body: some View { Circle().fill(Palette.tag(name, in: store.vocabulary)).frame(width: 8, height: 8).accessibilityHidden(true) }
}

struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Palette.meta)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

extension View {
    func pickerTitle() -> some View {
        font(.system(size: 11, weight: .semibold)).textCase(.uppercase).tracking(0.4).foregroundStyle(Palette.meta)
    }

    func pickerChip(on: Bool) -> some View {
        font(.system(size: 12, weight: .medium))
            .foregroundStyle(on ? Palette.panel : Palette.ink)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(on ? Palette.panelInk : Color.white.opacity(0.75), in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.panelInk.opacity(on ? 1 : 0.14)))
    }

    func chip(fill: Color) -> some View {
        font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(fill, in: Capsule())
    }

    func emptyNote() -> some View {
        font(.system(size: 13))
            .foregroundStyle(Palette.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
    }
}

/// Left-to-right rows that wrap, for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
