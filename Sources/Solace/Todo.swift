import SwiftUI

struct TodoItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var done = false
    var doneAt: Date?
}

struct TodoList: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var items: [TodoItem]
    var completedCollapsed: Bool?

    var active: [TodoItem] { items.filter { !$0.done } }
    /// Most recently completed first.
    var completed: [TodoItem] {
        items.filter(\.done).sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }
}

extension Notification.Name {
    static let solaceNewTodo = Notification.Name("solace.newTodo")
}

@MainActor
final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    @Published var lists: [TodoList] {
        didSet { if loaded { saver.schedule(lists) } }
    }
    private let saver = DebouncedSaver<[TodoList]>("lists.json")
    func flush() { saver.flush() }
    @Published var selectedID: UUID {
        didSet { UserDefaults.standard.set(selectedID.uuidString, forKey: "todo.selected") }
    }
    private var loaded = false

    init() {
        var initial = Storage.load([TodoList].self, "lists.json") ?? []
        if initial.isEmpty {
            initial = [TodoList(name: "To Do", items: Storage.legacyHaloTodos())]
        }
        lists = initial
        let saved = UserDefaults.standard.string(forKey: "todo.selected").flatMap { UUID(uuidString: $0) }
        if let saved, initial.contains(where: { $0.id == saved }) {
            selectedID = saved
        } else {
            selectedID = initial[0].id
        }
        loaded = true
        Storage.save(lists, "lists.json")
    }

    var selectedIndex: Int { lists.firstIndex { $0.id == selectedID } ?? 0 }
    var selected: TodoList { lists[selectedIndex] }

    // MARK: Lists

    @discardableResult
    func addList(name: String = "New List") -> UUID {
        let list = TodoList(name: name, items: [])
        lists.append(list)
        selectedID = list.id
        return list.id
    }

    func rename(list id: UUID, to name: String) {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        lists[i].name = trimmed.isEmpty ? (i == 0 ? "To Do" : "Untitled") : trimmed
    }

    func delete(list id: UUID) {
        guard lists.count > 1, let i = lists.firstIndex(where: { $0.id == id }) else { return }
        lists.remove(at: i)
        if selectedID == id { selectedID = lists[max(0, i - 1)].id }
    }

    func replaceAll(_ new: [TodoList]) {
        lists = new.isEmpty ? [TodoList(name: "To Do", items: [])] : new
        selectedID = lists[0].id
    }

    func toggleCompletedCollapsed() {
        let i = selectedIndex
        lists[i].completedCollapsed = !(lists[i].completedCollapsed ?? false)
    }

    // MARK: Items (in the selected list)

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lists[selectedIndex].items.append(TodoItem(text: t))
    }

    /// Ticking sends an item to the Completed section; unticking puts it at the end of the active items.
    func toggle(_ id: UUID) {
        let l = selectedIndex
        guard let i = lists[l].items.firstIndex(where: { $0.id == id }) else { return }
        var item = lists[l].items.remove(at: i)
        item.done.toggle()
        item.doneAt = item.done ? Date() : nil
        lists[l].items.append(item)
    }

    func delete(item id: UUID) {
        lists[selectedIndex].items.removeAll { $0.id == id }
    }

    func clearCompleted() {
        lists[selectedIndex].items.removeAll { $0.done }
    }

    /// Reorders active items only; completed items keep their own order.
    func moveActive(from source: IndexSet, to destination: Int) {
        let l = selectedIndex
        var active = lists[l].active
        active.move(fromOffsets: source, toOffset: destination)
        lists[l].items = active + lists[l].items.filter(\.done)
    }

    func text(for id: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in
                guard let self else { return "" }
                return self.selected.items.first { $0.id == id }?.text ?? ""
            },
            set: { [weak self] new in
                guard let self else { return }
                let l = self.selectedIndex
                if let i = self.lists[l].items.firstIndex(where: { $0.id == id }) { self.lists[l].items[i].text = new }
            }
        )
    }
}

// MARK: - View

private enum TodoRowKind: Identifiable {
    case item(TodoItem)
    case completedHeader(Int)

    var id: String {
        switch self {
        case .item(let t): return t.id.uuidString
        case .completedHeader: return "completed-header"
        }
    }
}

private enum TodoFocus: Hashable { case newItem, rename }

struct TodoView: View {
    @EnvironmentObject private var store: TodoStore
    private let draft = State(initialValue: "")
    private let renamingID = State<UUID?>(initialValue: nil)
    private let renameText = State(initialValue: "")
    private let pendingDelete = State<UUID?>(initialValue: nil)
    @FocusState private var focus: TodoFocus?

    var body: some View {
        let list = store.selected
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(list.name)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1)
                Spacer()
                if list.items.contains(where: \.done) {
                    Button("Clear Done") { withAnimation(.snappy) { store.clearCompleted() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.label)
                }
                Text("\(list.active.count)")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Ink.dim)
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)

            listTabs
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 6)

            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Ink.label)
                TextField("New To-Do", text: draft.projectedValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focus, equals: .newItem)
                    .onSubmit {
                        withAnimation(.snappy) { store.add(draft.wrappedValue) }
                        draft.wrappedValue = ""
                        focus = .newItem
                    }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 10)

            List {
                ForEach(rows(for: list)) { row in
                    switch row {
                    case .item(let item):
                        TodoRow(item: item,
                                text: store.text(for: item.id),
                                onToggle: { withAnimation(.snappy(duration: 0.35)) { store.toggle(item.id) } },
                                onDelete: { withAnimation(.snappy) { store.delete(item: item.id) } })
                            .listRowSeparator(.hidden)
                    case .completedHeader(let count):
                        completedHeader(count: count, collapsed: list.completedCollapsed ?? false)
                            .listRowSeparator(.hidden)
                            .moveDisabled(true)
                    }
                }
                .onMove { source, destination in
                    let activeCount = store.selected.active.count
                    guard source.allSatisfy({ $0 < activeCount }) else { return }
                    store.moveActive(from: source, to: min(destination, activeCount))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 14)
            .id(store.selectedID)
        }
        .onAppear { if store.selected.items.isEmpty { focus = .newItem } }
        .onReceive(NotificationCenter.default.publisher(for: .solaceNewTodo)) { _ in focus = .newItem }
        .onChange(of: focus) { old, new in
            if old == .rename && new != .rename { commitRename() }
        }
        .confirmationDialog(
            "Delete this list?",
            isPresented: Binding(get: { pendingDelete.wrappedValue != nil },
                                 set: { if !$0 { pendingDelete.wrappedValue = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete List", role: .destructive) {
                if let id = pendingDelete.wrappedValue { withAnimation(.snappy) { store.delete(list: id) } }
                pendingDelete.wrappedValue = nil
            }
        } message: {
            Text("All items in it will be removed.")
        }
    }

    private func rows(for list: TodoList) -> [TodoRowKind] {
        var rows = list.active.map { TodoRowKind.item($0) }
        let done = list.completed
        if !done.isEmpty {
            rows.append(.completedHeader(done.count))
            if !(list.completedCollapsed ?? false) { rows += done.map { .item($0) } }
        }
        return rows
    }

    private func completedHeader(count: Int, collapsed: Bool) -> some View {
        Button {
            withAnimation(.snappy) { store.toggleCompletedCollapsed() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text("Completed · \(count)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Ink.label)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: List tabs

    private var listTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.lists) { list in
                    if renamingID.wrappedValue == list.id {
                        TextField("List name", text: renameText.projectedValue)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .focused($focus, equals: .rename)
                            .onSubmit { commitRename() }
                            .frame(width: 130)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color(white: 0.16)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                    } else {
                        let selected = list.id == store.selectedID
                        Text(list.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected ? Color.white : Ink.label)
                            .lineLimit(1)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(selected ? Color(white: 0.16) : Ink.surface))
                            .overlay(Capsule().strokeBorder(Ink.stroke, lineWidth: 1))
                            .contentShape(Capsule())
                            .onTapGesture { if store.selectedID != list.id { store.selectedID = list.id } }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(list) })
                            .contextMenu {
                                Button("Rename") { startRename(list) }
                                Button("Delete List", role: .destructive) { pendingDelete.wrappedValue = list.id }
                                    .disabled(store.lists.count < 2)
                            }
                            .help("Double-click to rename")
                    }
                }
                Button {
                    let id = store.addList()
                    if let list = store.lists.first(where: { $0.id == id }) { startRename(list) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.label)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Ink.surface))
                        .overlay(Circle().strokeBorder(Ink.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("New list")
            }
            .padding(.vertical, 2)
        }
    }

    private func startRename(_ list: TodoList) {
        store.selectedID = list.id
        renameText.wrappedValue = list.name
        renamingID.wrappedValue = list.id
        DispatchQueue.main.async { focus = .rename }
    }

    private func commitRename() {
        guard let id = renamingID.wrappedValue else { return }
        store.rename(list: id, to: renameText.wrappedValue)
        renamingID.wrappedValue = nil
    }
}

struct TodoRow: View {
    let item: TodoItem
    let text: Binding<String>
    var onToggle: () -> Void
    var onDelete: () -> Void
    private let hovering = State(initialValue: false)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(item.done ? Color(white: 0.55) : Color(white: 0.6))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            TextField("", text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .strikethrough(item.done, color: Ink.label)
                .foregroundStyle(item.done ? Ink.label : Color.white)
                .padding(.top, 1)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.label)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .opacity(hovering.wrappedValue ? 1 : 0)
            .help("Delete")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering.wrappedValue = $0 }
        .contextMenu {
            Button(item.done ? "Mark as Not Done" : "Mark as Done", action: onToggle)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
