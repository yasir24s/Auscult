import SwiftUI
import UniformTypeIdentifiers
import AuscultKit

struct DeviceDetailView: View {
    let device: DeviceSnapshot
    @Environment(AppModel.self) private var model
    @State private var exportFormat: AppModel.ExportFormat = .text
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 0) {
            DeviceHeader(device: device, report: model.selectedReport)
            Divider()

            if model.runState.isRunning {
                RunProgressView()
            } else if let report = model.selectedReport {
                ReportView(report: report)
            } else {
                ReadyToRunView(device: device)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.runState.isRunning {
                    Button("Cancel", systemImage: "stop.fill") { model.cancelRun() }
                } else {
                    Button("Run Diagnostics", systemImage: "stethoscope") {
                        model.runDiagnostics(on: device)
                    }
                    .keyboardShortcut("d")
                }
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    ForEach(AppModel.ExportFormat.allCases) { f in
                        Button(f.rawValue) { exportFormat = f; isExporting = true }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(model.selectedReport == nil)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: model.selectedReport.flatMap {
                model.exportData($0, as: exportFormat).map(ReportDocument.init)
            },
            contentType: exportFormat == .json ? .json : (exportFormat == .csv ? .commaSeparatedText : .plainText),
            defaultFilename: model.selectedReport.map { model.suggestedFilename($0, exportFormat) }
        ) { _ in }
    }
}

// MARK: - Header

struct DeviceHeader: View {
    let device: DeviceSnapshot
    let report: DiagnosticReport?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: device.symbolName)
                .font(.system(size: 34, weight: .light))
                .frame(width: 44)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName).font(.title2.weight(.semibold))
                Text([device.marketingName, device.osDescription]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if device.isSimulator { Tag("simulator", .gray) }
                    if device.isPrereleaseOS { Tag("prerelease", .purple) }
                    Tag(device.link.rawValue, device.link == .usb ? .blue : .gray)
                    Tag(device.isReachable ? "connected" : "offline",
                        device.isReachable ? .green : .orange)
                    if let s = device.serialNumber { Tag(s, .secondary) }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)

            if let report {
                VerdictBadge(report: report)
            }
        }
        .padding(16)
    }
}

struct VerdictBadge: View {
    let report: DiagnosticReport

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Text(report.overallVerdict.symbol).font(.title2.weight(.bold))
                Text(report.overallVerdict.rawValue.uppercased())
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(report.overallVerdict.tint)

            HStack(spacing: 7) {
                ForEach([Verdict.fail, .error, .warn, .pass], id: \.self) { v in
                    if let n = report.tally[v], n > 0 {
                        HStack(spacing: 2) {
                            Circle().fill(v.tint).frame(width: 5, height: 5)
                            Text("\(n)").font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .foregroundStyle(.secondary)

            Text(report.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - States

struct RunProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            if case .running(let progress, let label) = model.runState {
                ProgressView(value: progress) {
                    Text(label).font(.callout)
                }
                .frame(maxWidth: 320)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReadyToRunView: View {
    let device: DeviceSnapshot
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "stethoscope")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Ready to diagnose").font(.title3.weight(.medium))

            if !device.isReachable {
                Text("This device isn't currently connected. Auscult will report what it can "
                     + "from cached identity, but hardware readings need a live USB link.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button("Run Diagnostics") { model.runDiagnostics(on: device) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Export document

struct ReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json, .commaSeparatedText] }
    let data: Data

    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
