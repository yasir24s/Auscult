import Foundation
import AuscultKit

/// `auscult memory` — the full resident-memory census.
///
/// Separate from `run` because "where did my RAM go" wants the whole process
/// table, not the top fifteen. Reads the most recent jetsam report, which is a
/// snapshot of the device at its worst moment for memory.
func runMemoryCommand(session: DiagnosticSession, selector: String?, limit: Int) async {
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

    guard let listing = try? await session.router.fetch(.crashLogIndex, for: device) else {
        print("Could not read the device's diagnostic directory.")
        return
    }
    let index = DiagnosticReportIndex.parse(listing)
    guard let entry = index.recent(.jetsam, limit: 1).first,
          let payload = try? await session.router.fetch(.crashLog(name: entry.path), for: device),
          let text = payload.text.string,
          let census = MemoryCensus.parse(text, date: entry.date)
    else {
        print("No readable memory snapshot on the device.")
        return
    }

    func mb(_ bytes: Int64) -> String { String(format: "%7.0f MB", Double(bytes) / 1_048_576) }

    let when = census.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown"
    print("""

    Memory census — \(device.displayName)
    Snapshot: \(when) (the moment iOS last killed a process for memory)

    KERNEL ACCOUNTING
      \(mb(census.kernel.wired))  wired          kernel and drivers, cannot be freed
      \(mb(census.kernel.active))  active         in use right now
      \(mb(census.kernel.inactive))  inactive       reclaimable, but reclaiming costs work
      \(mb(census.kernel.compressor))  compressed     pages squeezed to make room
      \(mb(census.kernel.purgeable))  purgeable      caches iOS can discard freely
      \(mb(census.kernel.free))  FREE

    BY CATEGORY
    """)

    for category in MemoryCensus.Category.allCases {
        let total = census.total(of: category)
        guard total > 0 else { continue }
        let count = census.processes.filter { $0.category == category }.count
        print("  \(mb(total))  \(category.rawValue) — \(count) process(es)")
    }

    let suspended = census.processes.filter(\.isSuspended)
    if !suspended.isEmpty {
        print("""

        HELD BY SUSPENDED APPS — \(mb(census.suspendedTotal)) across \(suspended.count) apps
        iOS keeps these in memory so they resume instantly. They use no CPU, but
        under pressure this is the memory being compressed and decompressed.
        """)
        for process in suspended.prefix(limit) {
            print("  \(mb(process.residentBytes))  \(process.name)")
        }
    }

    print("\nTOP \(limit) BY RESIDENT MEMORY")
    for (rank, process) in census.processes.prefix(limit).enumerated() {
        let states = process.states.isEmpty ? "" : "  [\(process.states.joined(separator: ","))]"
        print(String(format: "  %2d. %@  %-32@%@", rank + 1,
                     mb(process.residentBytes) as NSString,
                     process.name as NSString, states as NSString))
    }

    print("""

    \(census.processes.count) processes resident, summing to \
    \(mb(census.totalResident)) of directly-attributed memory. The rest is kernel,
    caches and the compressed store, which is why the categories above do not
    add up to the installed total.
    """)
}
