import Foundation

struct FavoriteCommand: Identifiable, Codable {
    var id      = UUID()
    var command: String     // full command string as built
    var label:   String     // display name
    var createdAt: Date
}

@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var favorites: [FavoriteCommand] = []

    private let key = "com.proxbuddy.favorites"

    init() { load() }

    func add(command: String, label: String) {
        guard !favorites.contains(where: { $0.command == command }) else { return }
        favorites.append(FavoriteCommand(command: command, label: label, createdAt: Date()))
        save()
    }

    func remove(_ fav: FavoriteCommand) {
        favorites.removeAll { $0.id == fav.id }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset dest: Int) {
        favorites.move(fromOffsets: source, toOffset: dest)
        save()
    }

    func isFavorited(command: String) -> Bool {
        favorites.contains { $0.command == command }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([FavoriteCommand].self, from: data)
        else { return }
        favorites = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
