#if canImport(SwiftUI)
import RetentionEngine
import SwiftUI

enum LabFormat {
    static func milliseconds(_ duration: Duration?) -> String {
        guard let duration else { return "—" }
        let parts = duration.components
        let value = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        return value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f%%", value * 100)
    }

    static func points(_ value: Double) -> String {
        String(format: "%+.1f pp", value * 100)
    }
}

extension DecisionPath {
    var tint: Color {
        switch self {
        case .personalized: return .green
        case .holdoutControl: return .indigo
        case .fallback: return .orange
        case .deferToApple: return .red
        case .replayed: return .blue
        }
    }

    var title: String {
        switch self {
        case .personalized: return "Personalized"
        case .holdoutControl: return "Holdout · control message"
        case .fallback(let reason): return "Safe fallback · \(reason.rawValue)"
        case .deferToApple: return "Deferred to Apple"
        case .replayed: return "Replayed (idempotent)"
        }
    }

    var symbol: String {
        switch self {
        case .personalized: return "person.crop.circle.badge.checkmark"
        case .holdoutControl: return "scalemass"
        case .fallback: return "shield.lefthalf.filled"
        case .deferToApple: return "arrow.uturn.backward.circle"
        case .replayed: return "arrow.triangle.2.circlepath"
        }
    }
}

struct LabCard<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary))
    }
}

struct LabHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.bold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.gray.opacity(0.10)))
    }
}

struct Chip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.14)))
            .foregroundStyle(tint)
    }
}

/// A 0–700 ms ruler showing where the time went and where the budget ends.
struct BudgetTimeline: View {
    let timings: StageTimings
    let budget: Duration
    let appleTimeout: Duration = EngineConfiguration.appleTimeout

    private func fraction(_ duration: Duration?) -> CGFloat {
        guard let duration else { return 0 }
        let total = Double(Saturating.microseconds(appleTimeout))
        guard total > 0 else { return 0 }
        return CGFloat(min(max(Double(Saturating.microseconds(duration)) / total, 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.green.opacity(0.18))
                        .frame(width: width * fraction(budget))
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.teal).frame(width: max(2, width * fraction(timings.featureLookup)))
                        Rectangle().fill(Color.purple).frame(width: width * fraction(timings.signing))
                    }
                    .frame(height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.leading, 0)
                    Rectangle().fill(Color.primary).frame(width: 2, height: 26).offset(x: width * fraction(timings.total) - 1)
                    Rectangle().fill(Color.green).frame(width: 2, height: 26).offset(x: width * fraction(budget) - 1)
                    Rectangle().fill(Color.red).frame(width: 2, height: 26).offset(x: width - 2)
                }
            }
            .frame(height: 26)
            HStack(spacing: 12) {
                Label("lookup \(LabFormat.milliseconds(timings.featureLookup))", systemImage: "square.fill").foregroundStyle(.teal)
                Label("signing \(LabFormat.milliseconds(timings.signing))", systemImage: "square.fill").foregroundStyle(.purple)
                Spacer()
                Text("budget \(LabFormat.milliseconds(budget)) · Apple 700 ms").foregroundStyle(.secondary)
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)
        }
    }
}

/// An approximation of Apple's Confirm Cancellation page with the chosen message, using Apple's
/// labels ("From the developer", "Accept Offer" / "Switch Plan", "Keep Subscription").
struct CancelSheetPreview: View {
    let header: String?
    let message: String?
    let actionTitle: String?
    let offerLabel: String?
    let isAppleFallback: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("Confirm Cancellation").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                if isAppleFallback {
                    Text("Apple shows the message configured in App Store Connect, or the default message.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("From the developer").font(.caption).foregroundStyle(.secondary)
                    Text(header ?? "—").font(.subheadline.weight(.semibold))
                    Text(message ?? "—").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.gray.opacity(0.10)))
            if let actionTitle {
                VStack(spacing: 4) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor))
                        .foregroundStyle(.white)
                    if let offerLabel {
                        Text(offerLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text("Cancel Subscription").foregroundStyle(.red)
                Spacer()
                Text("Keep Subscription").fontWeight(.semibold)
            }
            .font(.subheadline)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.quaternary))
    }
}

struct BarRow: View {
    let label: String
    let value: Int
    let maximum: Int
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).lineLimit(1).frame(width: 150, alignment: .leading)
            GeometryReader { proxy in
                let share = maximum > 0 ? CGFloat(value) / CGFloat(maximum) : 0
                RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.7)).frame(width: max(2, proxy.size.width * share))
            }
            .frame(height: 10)
            Text("\(value)").font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
        }
    }
}
#endif
