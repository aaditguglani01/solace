import Foundation
import AppKit
import UniformTypeIdentifiers

/// Small JSON files in ~/Library/Application Support/Solace. Nothing leaves the Mac.
enum Storage {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Solace", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    /// One-time carry-over of settings from the earlier "Halo" builds.
    static func migrateSettingsFromHalo() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromHalo") else { return }
        d.set(true, forKey: "migratedFromHalo")
        if let old = d.persistentDomain(forName: "com.guglani.halo") {
            for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
        }
    }

    /// To-dos saved by the old "Halo" build, if any.
    static func legacyHaloTodos() -> [TodoItem] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Halo/todos.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TodoItem].self, from: data)) ?? []
    }
}

/// Coalesces rapid changes (typing, ticking) into one background write ~0.4 s later,
/// so the UI never waits on the disk.
@MainActor
final class DebouncedSaver<T: Encodable> {
    private let name: String
    private var pending: DispatchWorkItem?
    private var latest: T?

    init(_ name: String) { self.name = name }

    func schedule(_ value: T) {
        latest = value
        pending?.cancel()
        let file = name
        let item = DispatchWorkItem { Storage.save(value, file) }
        pending = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Write immediately (used when the app quits).
    func flush() {
        pending?.cancel()
        pending = nil
        if let latest { Storage.save(latest, name) }
        latest = nil
    }
}

// MARK: - Backup & restore

struct BackupFile: Codable {
    var app: String
    var version: Int
    var exportedAt: Date
    var lists: [TodoList]
    var subjects: [Subject]
    var exams: [Exam]
    var sessions: [FocusSession]
}

@MainActor
enum Backup {
    static func export() {
        let file = BackupFile(app: "Solace", version: 1, exportedAt: Date(),
                              lists: TodoStore.shared.lists,
                              subjects: SyllabusStore.shared.subjects,
                              exams: ExamStore.shared.exams,
                              sessions: FocusLog.shared.sessions)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Solace Backup \(Date().formatted(.iso8601.year().month().day())).json"
        panel.message = "Save a copy of your lists, syllabus, exams and study time."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Storage.encoder.encode(file) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            alert("Couldn't save the backup", error.localizedDescription)
        }
    }

    static func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Solace backup file."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let file = try? Storage.decoder.decode(BackupFile.self, from: data), file.app == "Solace" else {
            alert("That isn't a Solace backup", "Choose a file made with File › Export Backup.")
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Replace everything with this backup?"
        confirm.informativeText = "Your current to-do lists, syllabus, exams and study time will be replaced by the backup from \(file.exportedAt.formatted(date: .abbreviated, time: .shortened))."
        confirm.addButton(withTitle: "Replace")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        TodoStore.shared.replaceAll(file.lists)
        SyllabusStore.shared.subjects = file.subjects
        ExamStore.shared.exams = file.exams
        FocusLog.shared.replaceAll(file.sessions)
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
