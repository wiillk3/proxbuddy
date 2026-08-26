import Foundation
import Combine

@MainActor
final class DeviceManager: ObservableObject {
    @Published var sessions: [PM3Session] = []
    @Published var activeIndex: Int = 0

    private var cancellables = [UUID: AnyCancellable]()

    var activeSession: PM3Session? {
        sessions.indices.contains(activeIndex) ? sessions[activeIndex] : nil
    }

    // MARK: - Session management

    @discardableResult
    func addSession(label: String? = nil) -> PM3Session {
        let name = label ?? "PM5 \(sessions.count + 1)"
        let s = PM3Session(label: name)
        cancellables[s.id] = s.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessions.append(s)
        return s
    }

    func removeSession(_ session: PM3Session) {
        guard sessions.count > 1 else { return }
        session.terminate()
        cancellables.removeValue(forKey: session.id)
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions.remove(at: idx)
            activeIndex = min(activeIndex, sessions.count - 1)
        }
    }

    func setActive(_ session: PM3Session) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            activeIndex = idx
        }
    }
}
