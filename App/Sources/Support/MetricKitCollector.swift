import AgentCore
import MetricKit

/// Saves Apple-provided crash and hang payloads into the same private diagnostics folder as
/// ordinary errors. MetricKit may deliver a payload on a later launch.
final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let diagnostics: DiagnosticsLog

    init(diagnostics: DiagnosticsLog) {
        self.diagnostics = diagnostics
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
        for payload in MXMetricManager.shared.pastDiagnosticPayloads {
            let data = payload.jsonRepresentation()
            Task { await diagnostics.recordMetricPayload(data) }
        }
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let values = payloads.map { $0.jsonRepresentation() }
        Task { [diagnostics] in
            for value in values { await diagnostics.recordMetricPayload(value) }
        }
    }
}
