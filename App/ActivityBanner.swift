import SwiftUI

/// Shows the slow operation in progress (AppModel.activity): what is happening and, while files download, how far
/// along it is. Placed at the bottom of the window and of sheets, which would otherwise cover it on iPhone.
struct ActivityBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let a = model.activity {
                Group {
                    if a.total > 0 {
                        // Title above the bar, so neither is cut short on a narrow iPhone.
                        VStack(alignment: .leading, spacing: 6) {
                            Text(a.title).font(.callout).lineLimit(1)
                            HStack(spacing: 10) {
                                ProgressView(value: Double(a.done), total: Double(a.total)).frame(minWidth: 120)
                                Text("\(a.done) of \(a.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: 320)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(a.title).font(.callout).lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .padding(.bottom, 16)
                .padding(.horizontal)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.snappy, value: model.activity?.title)
        .allowsHitTesting(false)
    }
}

extension View {
    /// Overlays the activity banner (see `ActivityBanner`).
    func activityBanner() -> some View {
        overlay(alignment: .bottom) { ActivityBanner() }
    }
}

/// Full-screen progress for the first download, when there is nothing to show yet.
struct FirstDownloadView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            if let a = model.activity, a.total > 0 {
                ProgressView(value: Double(a.done), total: Double(a.total)).frame(maxWidth: 260)
                Text("\(a.done) of \(a.total) files").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Text(model.activity?.title ?? "Connecting to GitHub…").font(.headline)
        }
        .padding()
    }
}
