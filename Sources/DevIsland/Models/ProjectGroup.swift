import Foundation
import Combine

/// 一个项目组：把若干仓库目录归为一组，便于一条指令分发给全组。
struct ProjectGroup: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var dirs: [String]

    init(id: String = UUID().uuidString, name: String, dirs: [String]) {
        self.id = id
        self.name = name
        self.dirs = dirs
    }
}

/// 项目组的持久化存储（写入 UserDefaults）
@MainActor
final class ProjectGroupStore: ObservableObject {
    static let shared = ProjectGroupStore()
    private let key = "projectGroups"

    @Published private(set) var groups: [ProjectGroup] = []

    private init() { load() }

    func add(name: String, dirs: [String]) {
        groups.append(ProjectGroup(name: name, dirs: dirs))
        save()
    }

    func remove(_ group: ProjectGroup) {
        groups.removeAll { $0.id == group.id }
        save()
    }

    func update(_ group: ProjectGroup) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx] = group
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ProjectGroup].self, from: data) else { return }
        groups = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
