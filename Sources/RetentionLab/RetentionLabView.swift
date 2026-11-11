#if canImport(SwiftUI) && canImport(Observation)
import RetentionAttribution
import RetentionCopy
import RetentionEngine
import SwiftUI

/// The lab: the hot path, the load test and the offline AI pipeline, side by side.
@MainActor
public struct RetentionLabView: View {
    @State private var model: LabModel

    /// - Parameters:
    ///   - configuration: The engine configuration (app ID, budget, holdout, offer policy). The host
    ///     app owns it, exactly as a server would own its deployment config.
    ///   - options: Launch options, for scripted runs.
    public init(configuration: EngineConfiguration, options: LabLaunchOptions = LabLaunchOptions()) {
        _model = State(initialValue: LabModel(configuration: configuration, options: options))
    }

    public var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            DecideView(model: model)
                .tabItem { Label("Cancel sheet", systemImage: "hand.raised.fill") }
                .tag(LabTab.decide)
            LoadView(model: model)
                .tabItem { Label("p99 under load", systemImage: "speedometer") }
                .tag(LabTab.load)
            CopyView(model: model)
                .tabItem { Label("AI copy", systemImage: "sparkles") }
                .tag(LabTab.copy)
        }
        .task { await model.start() }
    }
}

// MARK: - Cancel sheet

struct DecideView: View {
    let model: LabModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
            }
            .onChange(of: model.completedRuns) {
                withAnimation { proxy.scrollTo("decision-result", anchor: .top) }
            }
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 14) {
                LabHeader(
                    title: "Apple calls. You have 700 ms.",
                    subtitle: "Pick a subscriber, break a dependency, and watch the engine answer inside its budget anyway."
                )
                if let error = model.startupError {
                    Text(error).foregroundStyle(.red)
                }
                personaPicker
                faultsCard
                Button {
                    Task { await model.simulate() }
                } label: {
                    Label(model.isSimulating ? "Waiting for the engine…" : "Send Apple's request", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.rig == nil || model.isSimulating)
                if let run = model.lastRun {
                    VStack(alignment: .leading, spacing: 14) { result(run) }
                        .id("decision-result")
                }
            }
            .padding()
    }

    private var personaPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.personas) { persona in
                    Button {
                        model.personaID = persona.id
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(persona.name) · \(persona.locale)").font(.subheadline.weight(.semibold))
                            Text(persona.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(width: 168, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(persona.id == model.selectedPersona?.id ? Color.accentColor.opacity(0.16) : Color.gray.opacity(0.10))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var faultsCard: some View {
        LabCard("Faults") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote feature lookup").font(.caption).foregroundStyle(.secondary)
                Picker("Remote lookup", selection: Binding(get: { model.faults.remote }, set: { model.setRemote($0) })) {
                    ForEach(RemoteLatency.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Promotional-offer signer").font(.caption).foregroundStyle(.secondary)
                Picker("Signer", selection: Binding(get: { model.faults.signer }, set: { model.setSigner($0) })) {
                    ForEach(SignerBehavior.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Toggle("Deliver the request twice, concurrently", isOn: Binding(get: { model.faults.duplicateDelivery }, set: { model.setDuplicateDelivery($0) }))
            Toggle("Request for another app (appAppleId)", isOn: Binding(get: { model.faults.wrongAppAppleId }, set: { model.setWrongAppAppleId($0) }))
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func result(_ run: LabRun) -> some View {
        let decision = run.response.decision
        LabCard("Decision") {
            HStack(spacing: 8) {
                if let path = decision?.path {
                    Label(path.title, systemImage: path.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(path.tint)
                } else if let rejection = run.response.rejection {
                    Label("Rejected · \(rejection.rawValue)", systemImage: "xmark.octagon.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Spacer()
                Chip(text: "HTTP \(run.response.status)", tint: run.response.status == 200 ? .green : .red)
                Chip(text: LabFormat.milliseconds(run.response.elapsed), tint: .primary)
            }
            if let decision {
                BudgetTimeline(timings: decision.timings, budget: model.configuration.responseBudget)
                if !decision.notes.isEmpty {
                    FlowLayoutChips(items: decision.notes.map(\.rawValue))
                }
            }
            if let duplicate = run.duplicate {
                let identical = duplicate.body == run.response.body
                Label(
                    identical ? "Duplicate delivery answered from the in-flight run — byte-identical response" : "Duplicate delivery returned a different response",
                    systemImage: identical ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(identical ? .green : .red)
            }
        }
        CancelSheetPreview(
            header: run.header,
            message: run.body,
            actionTitle: run.actionTitle,
            offerLabel: run.offerLabel,
            isAppleFallback: run.response.status != 200
        )
        LabCard("Response body") {
            Text(run.responseJSON).font(.caption.monospaced()).textSelection(.enabled)
        }
        LabCard("Decoded request (signedPayload)") {
            Text(run.requestJSON).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if let world = model.world {
            Text("Catalog \(world.catalog.version) · demo verifier accepts any signature (production plugs in Apple's App Store Server Library)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Wrapping chips without a custom Layout: rows of up to three.
struct FlowLayoutChips: View {
    let items: [String]

    /// Repeats are dropped (a rule that fires in header and body is one chip): `ForEach` needs unique IDs.
    init(items: [String]) {
        var seen = Set<String>()
        self.items = items.filter { seen.insert($0).inserted }
    }

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    ForEach(rows[index], id: \.self) { Chip(text: $0) }
                }
            }
        }
    }
}

// MARK: - Load

struct QuantileRow: Identifiable {
    let label: String
    let quantile: Double
    var id: String { label }
    static let standard = [
        QuantileRow(label: "p50", quantile: 0.50),
        QuantileRow(label: "p95", quantile: 0.95),
        QuantileRow(label: "p99", quantile: 0.99),
        QuantileRow(label: "p99.9", quantile: 0.999),
    ]
}

struct LoadView: View {
    let model: LabModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
            }
            .onChange(of: model.completedLoads) {
                withAnimation { proxy.scrollTo("load-results", anchor: .top) }
            }
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 14) {
                LabHeader(
                    title: "p99, not the average.",
                    subtitle: "\(LabRig.defaultLoadRequests.formatted()) cancellation requests at \(Saturating.int(LabRig.defaultLoadRate))/s against the real engine: 45% need a remote lookup that is sometimes slow or hung, and one \(LabFormat.milliseconds(LabRig.defaultStall)) stall hits a quarter of the way in."
                )
                Button {
                    Task { await model.runLoad() }
                } label: {
                    Label(model.isRunningLoad ? "Running open loop, then closed loop…" : "Run the load test (≈10 s)", systemImage: "bolt.horizontal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.world == nil || model.isRunningLoad)
                if model.isRunningLoad { ProgressView().frame(maxWidth: .infinity) }
                if let load = model.load {
                    VStack(alignment: .leading, spacing: 14) { results(load) }
                        .id("load-results")
                }
            }
            .padding()
    }

    @ViewBuilder
    private func results(_ load: LoadComparison) -> some View {
        let open = load.openLoop.fromIntendedStart
        let closed = load.closedLoop.fromActualStart
        LabCard("Same server, same \(LabFormat.milliseconds(load.stall)) stall") {
            let openP99 = open.quantile(0.99) ?? .zero
            let closedP99 = closed.quantile(0.99) ?? .zero
            Text("Open loop, measured from when Apple would have sent each request: p99 = \(LabFormat.milliseconds(openP99)). Closed loop, same traffic: p99 = \(LabFormat.milliseconds(closedP99)).")
                .font(.subheadline)
            if openP99 > closedP99 + .milliseconds(25) {
                Text("The closed-loop harness under-reports by \(LabFormat.milliseconds(openP99 - closedP99)) — coordinated omission: it stops sending while the server is stuck, so the requests that would have queued behind the stall are never measured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This run the two agree within 25 ms; the stall was too short relative to the slowest lookups to move p99. The open-loop number is still the one to trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        LabCard("Latency") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("").font(.caption)
                    Text("Open loop").font(.caption.weight(.semibold))
                    Text("Closed loop").font(.caption.weight(.semibold))
                }
                ForEach(QuantileRow.standard) { row in
                    let (label, q) = (row.label, row.quantile)
                    GridRow {
                        Text(label).font(.caption.monospaced())
                        Text(LabFormat.milliseconds(open.quantile(q))).font(.callout.monospacedDigit().weight(label == "p99" ? .bold : .regular))
                        Text(LabFormat.milliseconds(closed.quantile(q))).font(.callout.monospacedDigit())
                    }
                }
                GridRow {
                    Text("max").font(.caption.monospaced())
                    Text(LabFormat.milliseconds(open.maximumMicroseconds.map { Duration.microseconds($0) })).font(.callout.monospacedDigit())
                    Text(LabFormat.milliseconds(closed.maximumMicroseconds.map { Duration.microseconds($0) })).font(.callout.monospacedDigit())
                }
                GridRow {
                    Text("mean").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(LabFormat.milliseconds(open.mean)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text(LabFormat.milliseconds(closed.mean)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack {
                StatTile(value: "\(load.openLoop.lateAgainstApple)", label: "open-loop answers later than Apple's 700 ms", tint: load.openLoop.lateAgainstApple == 0 ? .green : .red)
                StatTile(value: "\(load.requests)", label: "requests per run")
            }
        }
        LabCard("What the open-loop requests got") {
            let rows = load.openLoop.labels.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            let maximum = rows.first?.value ?? 0
            ForEach(rows, id: \.key) { row in
                BarRow(label: row.key, value: row.value, maximum: maximum, tint: row.key.hasPrefix("fallback") ? .orange : row.key == "holdout-control" ? .indigo : .green)
            }
        }
        readout(load.readout)
    }

    @ViewBuilder
    private func readout(_ readout: ExperimentReadout) -> some View {
        LabCard("Experiment readout · simulated subscriber behaviour") {
            ForEach([readout.treatment, readout.holdout], id: \.arm) { arm in
                HStack {
                    Text(arm.arm == .treatment ? "Treatment" : "Holdout").font(.subheadline.weight(.semibold)).frame(width: 90, alignment: .leading)
                    Text("cancelled \(arm.cancelled) of \(arm.resolvedSubscribers)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let interval = arm.cancellationInterval {
                        Text("\(LabFormat.percent(arm.cancellationRate))  [\(LabFormat.percent(interval.lowerBound)), \(LabFormat.percent(interval.upperBound))]")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            if let prevented = readout.preventedCancellations {
                Text("Cancellations prevented: \(LabFormat.points(prevented.estimate)) [\(LabFormat.points(prevented.lower)), \(LabFormat.points(prevented.upper))]\(prevented.isSignificant ? "" : " — not significant")")
                    .font(.subheadline.weight(.semibold))
            }
            Text("The join and the intervals are the real code (per subscriber, Wilson and Newcombe 95%). The subscribers are a seeded model.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Copy pipeline

struct CopyView: View {
    let model: LabModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LabHeader(
                    title: "The LLM writes offline. A gate decides.",
                    subtitle: "Claude drafts localized variants in a back-office job; deterministic rules reject what App Review would; only APPROVED messages are compiled into the catalog the 700 ms path reads."
                )
                if let world = model.world {
                    content(world)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func content(_ world: LabWorld) -> some View {
        let report = world.pipelineReport
        let compiled = world.compileResult
        LabCard("Pipeline") {
            HStack(spacing: 6) {
                ForEach(["Brief", "Draft", "Gate", "App Review", "Catalog"], id: \.self) { step in
                    Text(step).font(.caption2.weight(.semibold)).padding(6).background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    if step != "Catalog" { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                StatTile(value: "\(report.drafts.count)", label: "variants drafted")
                StatTile(value: "\(report.passed.count)", label: "passed the gate", tint: .green)
                StatTile(value: "\(report.rejected.count)", label: "rejected", tint: .red)
                StatTile(value: "\(compiled.awaitingApproval.count)", label: "awaiting upload or review", tint: .orange)
                StatTile(value: "\(compiled.uploads.count)", label: "uploads planned")
                StatTile(value: "\(world.catalog.entryCount)", label: "live catalog entries", tint: .green)
            }
            Text("Catalog version \(world.catalog.version) · drafter: ScriptedCopyDrafter (deterministic stand-in; ClaudeCopyDrafter is the production adapter)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        LabCard("Why variants were rejected") {
            let rows = report.rejectionsByRule.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            let maximum = rows.first?.value ?? 0
            ForEach(rows, id: \.key) { row in
                BarRow(label: row.key, value: row.value, maximum: maximum, tint: .red)
            }
        }
        LabCard("Rejected examples") {
            ForEach(Array(report.rejected.prefix(5).enumerated()), id: \.offset) { _, draft in
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.candidate.header).font(.subheadline.weight(.semibold))
                    Text(draft.candidate.body).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    FlowLayoutChips(items: draft.verdict.blockingRuleIds)
                }
                Divider()
            }
        }
        LabCard("Live in the catalog") {
            let live = Set(world.catalog.keys.flatMap { world.catalog.entries(for: $0).map(\.messageIdentifier) })
            ForEach(Array(report.passed.filter { live.contains($0.messageIdentifier) }.prefix(4).enumerated()), id: \.offset) { _, draft in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(draft.candidate.header).font(.subheadline.weight(.semibold))
                        Spacer()
                        Chip(text: "\(draft.brief.locale) · \(draft.brief.segment.rawValue)", tint: .green)
                    }
                    Text(draft.candidate.body).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
            }
        }
    }
}
#endif
