import SwiftUI
import AuscultKit

struct ReportView: View {
    let report: DiagnosticReport
    @State private var expanded: Set<String> = []
    @State private var hideHealthy = false

    private var sections: [ReportSection] {
        report.populatedSections.filter { s in
            !hideHealthy || report.results(in: s).contains { $0.verdict >= .warn }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Only show findings", isOn: $hideHealthy)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                Spacer()
                Text("\(report.results.count) checks · \(String(format: "%.1fs", report.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.4))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(sections, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(section.rawValue.uppercased())
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)

                            ForEach(report.results(in: section)) { r in
                                if !hideHealthy || r.verdict >= .warn {
                                    ProbeCard(
                                        result: r,
                                        isExpanded: expanded.contains(r.probeID),
                                        toggle: { toggle(r.probeID) }
                                    )
                                    .padding(.horizontal, 12)
                                }
                            }
                        }
                    }

                    HostFooter(host: report.hostInfo, capabilityCount: report.capabilities.count)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
                .padding(.vertical, 14)
            }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

struct ProbeCard: View {
    let result: ProbeResult
    let isExpanded: Bool
    let toggle: () -> Void

    private var hasDetail: Bool { !result.metrics.isEmpty || result.diagnosticDetail != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 9) {
                    Text(result.verdict.symbol)
                        .font(.body.weight(.bold))
                        .foregroundStyle(result.verdict.tint)
                        .frame(width: 14)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title).font(.callout.weight(.medium))
                        Text(result.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 6)

                    if hasDetail {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)

            if isExpanded, hasDetail {
                Divider().padding(.leading, 33)
                VStack(alignment: .leading, spacing: 0) {
                    if let d = result.diagnosticDetail {
                        Text(d)
                            .font(.caption.monospaced())
                            .foregroundStyle(.purple)
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 33)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(result.metrics) { m in
                        MetricRow(metric: m)
                    }
                    if let served = result.servedBy {
                        Text("via \(served)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 33)
                            .padding(.vertical, 5)
                    }
                }
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 7))
        .overlay(alignment: .leading) {
            if result.verdict >= .warn {
                Rectangle()
                    .fill(result.verdict.tint)
                    .frame(width: 2.5)
                    .clipShape(.rect(cornerRadius: 2))
            }
        }
    }
}

struct MetricRow: View {
    let metric: Metric

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(metric.verdict == .info ? " " : metric.verdict.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(metric.verdict.tint)
                .frame(width: 10)

            Text(metric.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 168, alignment: .leading)

            Text(metric.formattedValue)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(metric.value == .absent ? .tertiary : .primary)

            if let note = metric.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 23)
        .padding(.vertical, 3)
    }
}

struct HostFooter: View {
    let host: HostInfo
    let capabilityCount: Int

    /// Is a newer bundle sitting on disk than the one we are running?
    static func isStale(_ stamp: String) -> Bool {
        guard let executable = Bundle.main.executableURL,
              let built = try? FileManager.default
                .attributesOfItem(atPath: executable.path)[.modificationDate] as? Date
        else { return false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let stamped = formatter.date(from: stamp) else { return false }
        // A minute of slack: the plist and the binary are written moments apart.
        return built.timeIntervalSince(stamped) > 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider().padding(.bottom, 5)
            Text("Auscult \(host.auscultVersion) · macOS \(host.macOSVersion)")
            // A rebuilt bundle does not replace a running process, so show
            // which build this window is actually running.
            if let stamp = Bundle.main.object(forInfoDictionaryKey: "AuscultBuildStamp") as? String {
                Text("build \(stamp)\(Self.isStale(stamp) ? " — RELAUNCH FOR A NEWER BUILD" : "")")
                    .foregroundStyle(Self.isStale(stamp) ? Color.orange : Color.secondary)
            }
            if let d = host.devicectlVersion { Text("devicectl \(d)") }
            if let c = host.cfgutilVersion { Text(c) }
            if let x = host.xcodeVersion { Text(x) }
            Text("\(capabilityCount) capabilities resolved for this device")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}
