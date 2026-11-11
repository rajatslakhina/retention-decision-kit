#if canImport(SwiftUI) && canImport(Observation)
import Foundation
import Observation
import RetentionEngine

/// The lab's state. All engine work runs off the main actor inside the rig; this only publishes results.
@MainActor
@Observable
public final class LabModel {
    public private(set) var world: LabWorld?
    public private(set) var rig: LabRig?
    public private(set) var startupError: String?

    public var selectedTab: LabTab
    public var personaID: String
    public private(set) var faults = LabFaults()

    public private(set) var lastRun: LabRun?
    public private(set) var isSimulating = false
    public private(set) var load: LoadComparison?
    public private(set) var isRunningLoad = false
    /// Bumped after each run, so the views can scroll the result into view.
    public private(set) var completedRuns = 0
    public private(set) var completedLoads = 0

    public let configuration: EngineConfiguration
    private let options: LabLaunchOptions
    @ObservationIgnored private var started = false

    public init(configuration: EngineConfiguration, options: LabLaunchOptions) {
        self.configuration = configuration
        self.options = options
        self.selectedTab = options.tab
        self.personaID = options.personaID ?? "maya"
        var initial = LabFaults()
        if let remote = options.remote { initial.remote = remote }
        if let signer = options.signer { initial.signer = signer }
        self.faults = initial
    }

    public var personas: [LabPersona] { world?.personas ?? [] }
    public var selectedPersona: LabPersona? { personas.first { $0.id == personaID } ?? personas.first }

    public func start() async {
        guard !started else { return }
        started = true
        do {
            let world = try await LabWorld.make(configuration: configuration)
            let rig = LabRig(world: world, faults: faults)
            self.world = world
            self.rig = rig
        } catch {
            startupError = String(describing: error)
            return
        }
        guard options.autoplay else { return }
        switch options.tab {
        case .decide: await simulate()
        case .load: await runLoad()
        case .copy: break  // The pipeline already ran while the world was built.
        }
    }

    public func setRemote(_ value: RemoteLatency) { updateFaults { $0.remote = value } }
    public func setSigner(_ value: SignerBehavior) { updateFaults { $0.signer = value } }
    public func setDuplicateDelivery(_ value: Bool) { updateFaults { $0.duplicateDelivery = value } }
    public func setWrongAppAppleId(_ value: Bool) { updateFaults { $0.wrongAppAppleId = value } }

    private func updateFaults(_ change: (inout LabFaults) -> Void) {
        var next = faults
        change(&next)
        faults = next
        rig?.setFaults(next)
    }

    public func simulate() async {
        guard let rig, let persona = selectedPersona, !isSimulating else { return }
        isSimulating = true
        lastRun = await rig.simulateCancellation(persona: persona)
        isSimulating = false
        completedRuns += 1
    }

    public func runLoad() async {
        guard let world, !isRunningLoad else { return }
        isRunningLoad = true
        load = await LabRig.runLoadComparison(world: world)
        isRunningLoad = false
        completedLoads += 1
    }
}
#endif
