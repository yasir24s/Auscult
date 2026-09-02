import Foundation
import Observation
import AuscultKit

/// All mutable app state. Kept on the main actor so views can read it directly.
@MainActor
@Observable
final class AppModel {
    struct TransportStatus: Identifiable {
        var id: String { name }
        let name: String
        let availability: TransportAvailability
    }

    enum RunState: Equatable {
        case idle
        case running(progress: Double, label: String)
        case finished

        var isRunning: Bool { if case .running = self { true } else { false } }
    }

    var devices: [DeviceSnapshot] = []
    var selectedDeviceID: DeviceSnapshot.ID?
    var reports: [DeviceSnapshot.ID: DiagnosticReport] = [:]
    var transports: [TransportStatus] = []
    var runState: RunState = .idle
    var discoveryErrors: [String] = []
    var isDiscovering = false
    var showSimulators = false

    private var session = DiagnosticSession()
    private var runTask: Task<Void, Never>?

    var visibleDevices: [DeviceSnapshot] {
        showSimulators ? devices : devices.filter { !$0.isSimulator }
    }

    var selectedDevice: DeviceSnapshot? {
        devices.first { $0.id == selectedDeviceID }
    }

    var selectedReport: DiagnosticReport? {
        selectedDeviceID.flatMap { reports[$0] }
    }

    var hasAnyTransport: Bool {
        transports.contains { $0.availability.isAvailable }
    }

    // MARK: Discovery

    func bootstrap() async {
        await refreshTransports()
        await refresh()

        // Dev hook: `AUSCULT_AUTORUN=1 open -a Auscult` runs the suite against
        // the first device as soon as it appears, so the report UI can be
        // exercised without driving the window by hand.
        if ProcessInfo.processInfo.environment["AUSCULT_AUTORUN"] == "1",
           let first = selectedDevice {
            runDiagnostics(on: first)
        }
    }

    func refreshTransports() async {
        transports = await session.transportStatus().map {
            TransportStatus(name: $0.name, availability: $0.availability)
        }
    }

    func refresh() async {
        isDiscovering = true
        defer { isDiscovering = false }

        // A fresh router each sweep: cached capabilities from a previous sweep
        // would hide a device that has since been plugged in or unlocked.
        session = DiagnosticSession()
        await refreshTransports()

        let (found, errors) = await session.devices()
        devices = found
        discoveryErrors = errors

        if let current = selectedDeviceID, !found.contains(where: { $0.id == current }) {
            selectedDeviceID = nil
        }
        if selectedDeviceID == nil {
            selectedDeviceID = visibleDevices.first(where: \.isReachable)?.id
                ?? visibleDevices.first?.id
        }
    }

    // MARK: Running

    func runDiagnostics(on device: DeviceSnapshot) {
        runTask?.cancel()
        runState = .running(progress: 0, label: "Preparing")
        runTask = Task { [weak self] in
            guard let self else { return }
            let report = await session.run(device) { progress in
                Task { @MainActor [weak self] in
                    guard self?.runState.isRunning == true else { return }
                    self?.runState = .running(
                        progress: progress.fraction, label: progress.currentTitle
                    )
                }
            }
            guard !Task.isCancelled else { return }
            reports[device.id] = report
            runState = .finished
        }
    }

    func cancelRun() {
        runTask?.cancel()
        runTask = nil
        runState = .idle
    }

    // MARK: Export

    enum ExportFormat: String, CaseIterable, Identifiable {
        case text = "Text", json = "JSON", csv = "CSV"
        var id: String { rawValue }
        var fileExtension: String {
            switch self { case .text: "txt"; case .json: "json"; case .csv: "csv" }
        }
    }

    func exportData(_ report: DiagnosticReport, as format: ExportFormat) -> Data? {
        switch format {
        case .text: Data(report.textReport().utf8)
        case .json: try? report.jsonData()
        case .csv: Data(report.csvReport().utf8)
        }
    }

    func suggestedFilename(_ report: DiagnosticReport, _ format: ExportFormat) -> String {
        let name = report.device.displayName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let stamp = report.startedAt.formatted(
            .iso8601.year().month().day().dateSeparator(.dash)
        )
        return "Auscult-\(name)-\(stamp).\(format.fileExtension)"
    }
}
