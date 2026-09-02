import Foundation
import AuscultKit

/// `auscult energy` — rank the processes iOS has caught misbehaving.
///
/// Separate from `run` because a drain investigation wants the full list and
/// the underlying report filenames, not a ten-row summary inside a report.
func runEnergyCommand(
    session: DiagnosticSession, selector: String?, limit: Int, detailFor: String?
) async {
    let (devices, _) = await session.devices()
    let candidates = devices.filter { !$0.isSimulator }
    let target = selector.flatMap { sel in
        candidates.first {
            $0.udid?.caseInsensitiveCompare(sel) == .orderedSame
                || $0.displayName.lowercased().contains(sel.lowercased())
        }
    } ?? candidates.first { $0.link == .usb } ?? candidates.first

    guard let device = target else {
        print("No device found. Connect one over USB.")
        return
    }

    print("Reading diagnostic reports from \(device.displayName)…")
    guard let listing = try? await session.router.fetch(.crashLogIndex, for: device) else {
        print("Could not read the device's diagnostic directory. Connect over USB and retry.")
        return
    }
    let index = DiagnosticReportIndex.parse(listing)
    guard !index.entries.isEmpty else {
        print("No diagnostic reports on the device.")
        return
    }

    // Detail mode: everything known about one process.
    if let wanted = detailFor {
        let matching = index.entries.filter {
            $0.process.lowercased().contains(wanted.lowercased())
        }
        guard !matching.isEmpty else {
            print("No reports mention '\(wanted)'.")
            return
        }
        print("\n\(matching.count) report(s) mentioning '\(wanted)':\n")
        for entry in matching.sorted(by: { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }) {
            let when: String = entry.date.map {
                $0.formatted(date: .abbreviated, time: .shortened)
            } ?? "unknown date"
            print("  \(when)  \(entry.kind.rawValue)")
            print("      \(entry.filename)")
        }

        // Open the resource reports for the actual numbers.
        let resourceReports = matching.filter { $0.kind.implicatesEnergy && $0.kind != .jetsam }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(5)
        if !resourceReports.isEmpty {
            print("\nDetail from the \(resourceReports.count) most recent:\n")
            for entry in resourceReports {
                guard let payload = try? await session.router.fetch(
                    .crashLog(name: entry.path), for: device
                ), let text = payload.text.string,
                   let report = ResourceReport.parse(text) else { continue }
                let when: String = report.date.map {
                    $0.formatted(date: .abbreviated, time: .shortened)
                } ?? "?"
                print("  \(when)  \(report.process) \(report.appVersion ?? "")")
                if let event = report.event { print("      event:  \(event)") }
                if let detail = report.detail { print("      detail: \(detail)") }
                if let bundle = report.bundleID { print("      bundle: \(bundle)") }
            }
        }
        return
    }

    let offenders = index.offenders(since: Date().addingTimeInterval(-14 * 24 * 3600))

    print("""

    \(index.entries.count) diagnostic reports on the device.

      CPU exhaustion        \(index.count(of: .cpuResource))
      Excessive wakeups     \(index.count(of: .wakeupsResource))
      Excessive disk writes \(index.count(of: .diskWritesResource))
      Memory kills          \(index.count(of: .jetsam))
      Kernel panics         \(index.count(of: .panic))
      Crash reports         \(index.count(of: .crash))

    Processes that exceeded a resource limit in the last 14 days, ranked by
    how strongly the reports implicate them in power consumption:
    """)

    for (rank, offender) in offenders.prefix(limit).enumerated() {
        let when: String = offender.mostRecent.map {
            $0.formatted(date: .abbreviated, time: .shortened)
        } ?? "?"
        print(String(format: "  %2d. %-28s %s", rank + 1, offender.process, offender.breakdown))
        print("      last: \(when)")
    }

    print("""

    CPU exhaustion is the strongest signal here: iOS writes one of those only
    when a process holds high CPU for minutes, which it cannot do without
    costing energy. Disk-write reports are weaker evidence.

    This is not a direct energy measurement — Settings › Battery does the
    authoritative per-app attribution. Use this to know where to look.

    For everything known about one process:
      auscult energy --detail <name>
    """)
}
