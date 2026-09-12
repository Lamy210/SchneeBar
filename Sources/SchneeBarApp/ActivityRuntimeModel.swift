import Observation
import SchneeBarCore

@MainActor
@Observable
final class ActivityRuntimeModel {
    var items: [ActivityItem] = []

    func replace(with items: [ActivityItem]) {
        self.items = items
    }
}
