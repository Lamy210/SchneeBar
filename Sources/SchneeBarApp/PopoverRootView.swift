import AppKit
import SchneeBarActivityFeature
import SchneeBarCore
import SchneeBarWidgetFeature
import SwiftUI

struct PopoverRootView: View {
    private static let activityWidgetID: WidgetID = "developer.activity"

    let model: WidgetRuntimeModel
    let activityModel: ActivityRuntimeModel

    var body: some View {
        VStack(spacing: 8) {
            WidgetOverviewView(snapshots: model.snapshots)

            if activityIsEnabled {
                Divider()
                    .padding(.horizontal, 12)

                if let selectedItem = activityModel.selectedItem,
                   activityModel.isPresentingDeliveryHistory
                {
                    DeliveryHistoryView(
                        repository: selectedItem.repository,
                        history: activityModel.deliveryHistory,
                        isLoading: activityModel.deliveryHistoryIsLoading,
                        errorMessage: activityModel.deliveryHistoryErrorMessage,
                        onBack: {
                            activityModel.dismissDeliveryHistory()
                        },
                        onRetry: {
                            activityModel.retryDeliveryHistory()
                        }
                    )
                } else if let selectedItem = activityModel.selectedItem {
                    ActivityDetailView(
                        item: selectedItem,
                        detail: activityModel.detail,
                        isLoading: activityModel.detailIsLoading,
                        errorMessage: activityModel.detailErrorMessage,
                        onBack: {
                            activityModel.dismissDetail()
                        },
                        onRetry: {
                            activityModel.retryDetail()
                        },
                        onShowHistory: {
                            activityModel.requestDeliveryHistory()
                        },
                        detailActionIsRunning:
                            activityModel.detailActionIsRunning,
                        detailActionErrorMessage:
                            activityModel.detailActionErrorMessage,
                        onAction: { action in
                            activityModel.performDetailAction(action)
                        }
                    )
                } else {
                    ActivityPopoverView(
                        items: activityModel.items,
                        onInspect: { item in
                            activityModel.requestDetail(for: item)
                        }
                    )
                }
            }

            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 12) {
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }

                Spacer(minLength: 12)

                Button("Quit SchneeBar") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var activityIsEnabled: Bool {
        guard let descriptor = model.descriptors.first(where: {
            $0.id == Self.activityWidgetID
        }) else {
            return false
        }
        return model.configuration.isEnabled(descriptor)
    }
}
