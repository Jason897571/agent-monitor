import AgentMonitorCore
import AppKit
import UniformTypeIdentifiers

/// Edits one skin folder: which file each pose plays, at what speed, and the skin's name.
///
/// Writes `skin.json` back in the same format a person would write by hand, so a skin
/// set up in the settings window can still be shared, diffed and edited in a text
/// editor.
@MainActor
final class SkinEditor: ObservableObject {

    struct Entry: Equatable {
        var file: String
        var speed: Double
    }

    let id: String
    let directory: URL
    @Published var name: String { didSet { save() } }
    @Published private(set) var entries: [PetPose: Entry]
    @Published private(set) var imageFiles: [String] = []
    /// Called after every save, so the pet can reload.
    var onChange: (() -> Void)?

    static let imageTypes: [UTType] = [.gif, .png, .webP, .heic, .jpeg]

    init?(id: String) {
        let directory = SkinLibrary.directory.appendingPathComponent(id, isDirectory: true)
        let url = directory.appendingPathComponent("skin.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.id = id
        self.directory = directory
        self.name = root["name"] as? String ?? id
        var entries: [PetPose: Entry] = [:]
        for (key, value) in root["poses"] as? [String: Any] ?? [:] {
            guard let pose = PetPose(rawValue: key) else { continue }
            if let file = value as? String {
                entries[pose] = Entry(file: file, speed: 1)
            } else if let object = value as? [String: Any], let file = object["file"] as? String {
                entries[pose] = Entry(file: file, speed: object["speed"] as? Double ?? 1)
            }
        }
        self.entries = entries
        rescanFiles()
    }

    /// Creates an empty skin folder and returns its id.
    static func create(named name: String) throws -> String {
        let base = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        var id = base.isEmpty ? "skin" : base
        var counter = 2
        while FileManager.default.fileExists(atPath: SkinLibrary.directory.appendingPathComponent(id).path) {
            id = "\(base)-\(counter)"
            counter += 1
        }
        let directory = SkinLibrary.directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": name, "poses": [String: Any]()]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            .write(to: directory.appendingPathComponent("skin.json"))
        return id
    }

    func entry(for pose: PetPose) -> Entry? { entries[pose] }

    func url(for pose: PetPose) -> URL? {
        entries[pose].map { directory.appendingPathComponent($0.file) }
    }

    /// `nil` clears the pose, so it falls back to its nearest relative.
    func setFile(_ file: String?, for pose: PetPose) {
        if let file {
            entries[pose] = Entry(file: file, speed: entries[pose]?.speed ?? 1)
        } else {
            entries[pose] = nil
        }
        save()
    }

    func setSpeed(_ speed: Double, for pose: PetPose) {
        guard var entry = entries[pose] else { return }
        entry.speed = speed
        entries[pose] = entry
        save()
    }

    /// Copies an image into the skin folder and assigns it to `pose`. Copied, not
    /// referenced: a skin must keep working after the Downloads folder is emptied.
    func importImage(from source: URL, for pose: PetPose) throws {
        let ext = source.pathExtension.isEmpty ? "gif" : source.pathExtension.lowercased()
        var name = "\(pose.rawValue).\(ext)"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
              entries[pose]?.file != name {
            name = "\(pose.rawValue)-\(counter).\(ext)"
            counter += 1
        }
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        rescanFiles()
        setFile(name, for: pose)
    }

    func rescanFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let extensions = Set(["gif", "png", "apng", "webp", "heic", "jpg", "jpeg"])
        imageFiles = files.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
    }

    private func save() {
        var poses: [String: Any] = [:]
        for (pose, entry) in entries {
            poses[pose.rawValue] = abs(entry.speed - 1) < 0.001
                ? entry.file
                : ["file": entry.file, "speed": (entry.speed * 100).rounded() / 100] as [String: Any]
        }
        let manifest: [String: Any] = ["name": name, "poses": poses]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        try? data.write(to: directory.appendingPathComponent("skin.json"), options: .atomic)
        onChange?()
    }

    /// Which agent states land on each pose — what the settings window tells the user a
    /// row is for.
    static func states(for pose: PetPose) -> String {
        switch pose {
        case .sleeping: return "没有 agent 在运行"
        case .waking: return "agent 刚启动（只播一次）"
        case .working: return "工作中"
        case .resting: return "空闲、shell"
        case .attentive: return "空闲一阵，值得看一眼"
        case .alert: return "等你批准权限 / 回答问题"
        case .digesting: return "压缩上下文"
        case .swarming: return "多个子 agent 并行"
        case .done: return "一轮刚完成"
        case .troubled: return "出错、额度用尽、崩溃、上下文将满"
        }
    }

    static func title(for pose: PetPose) -> String {
        switch pose {
        case .sleeping: return "睡觉"
        case .waking: return "醒来"
        case .working: return "工作"
        case .resting: return "休息"
        case .attentive: return "留意"
        case .alert: return "警觉"
        case .digesting: return "消化"
        case .swarming: return "忙碌"
        case .done: return "完成"
        case .troubled: return "出问题"
        }
    }
}
