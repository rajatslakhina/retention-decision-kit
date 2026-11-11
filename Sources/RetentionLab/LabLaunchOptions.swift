import Foundation

public enum LabTab: String, CaseIterable, Sendable, Hashable, Identifiable {
    case decide, load, copy
    public var id: String { rawValue }
}

/// Launch-time options, so a scripted Simulator run can open a tab and play its scenario without
/// anyone tapping (`xcrun simctl launch … -tab load -autoplay 1`).
public struct LabLaunchOptions: Sendable, Hashable {
    public var tab: LabTab
    public var autoplay: Bool
    public var personaID: String?
    public var remote: RemoteLatency?
    public var signer: SignerBehavior?

    public init(tab: LabTab = .decide, autoplay: Bool = false, personaID: String? = nil, remote: RemoteLatency? = nil, signer: SignerBehavior? = nil) {
        self.tab = tab
        self.autoplay = autoplay
        self.personaID = personaID
        self.remote = remote
        self.signer = signer
    }

    /// Parses `-tab <decide|load|copy> -autoplay <0|1> -persona <id> -remote <fast|slow|beyondBudget|hung> -signer <healthy|slow|failing>`.
    /// Unknown flags and values are ignored.
    public init(arguments: [String]) {
        self.init()
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if let raw = value(after: "-tab"), let tab = LabTab(rawValue: raw) { self.tab = tab }
        if let raw = value(after: "-autoplay") { autoplay = raw == "1" || raw.lowercased() == "yes" || raw.lowercased() == "true" }
        if let raw = value(after: "-persona") { personaID = raw }
        if let raw = value(after: "-remote") { remote = RemoteLatency(rawValue: raw) }
        if let raw = value(after: "-signer") { signer = SignerBehavior(rawValue: raw) }
    }
}
