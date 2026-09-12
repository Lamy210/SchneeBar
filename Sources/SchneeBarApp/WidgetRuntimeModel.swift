import Observation
import SchneeBarCore

@MainActor
@Observable
final class WidgetRuntimeModel {
    var snapshots: [WidgetSnapshot] = []
}
