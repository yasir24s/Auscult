import Foundation
import AuscultKit

/// `auscult parse-listing <file>` — run the report index over a saved
/// `devicectl device info files` JSON, with no device attached.
///
/// Exists so the classification and attribution logic can be checked against a
/// real listing offline. Getting host-versus-accessory attribution wrong is
/// silent — a Watch app's crashes simply appear in the phone's ranking — so it
/// needs to be verifiable without waiting for the right device to be plugged in.
func runParseListingCommand(path: String) {
    guard let data = FileManager.default.contents(atPath: path) else {
        print("Cannot read \(path)")
        return
    }
    let json = DynamicValue.parseJSON(data)
    let listing = json.result.exists ? json.result : json
    let index = DiagnosticReportIndex.parse(listing)

    guard !index.entries.isEmpty else {
        print("No diagnostic reports recognised in that listing.")
        return
    }

    let hostEntries = index.entries(from: .host)
    print("""

    Parsed \(index.entries.count) reports from \((path as NSString).lastPathComponent)

      this device        \(hostEntries.count)
      paired accessories \(index.entries.count - hostEntries.count)
    """)

    print("\n  BY KIND (this device)")
    for kind in DiagnosticReportIndex.Kind.allCases {
        let count = index.count(of: kind)
        if count > 0 { print("    \(kind.rawValue.padding(toLength: 24, withPad: " ", startingAt: 0)) \(count)") }
    }

    let offenders = index.offenders()
    if !offenders.isEmpty {
        print("\n  TOP OFFENDERS (this device only)")
        for offender in offenders.prefix(8) {
            print("    \(offender.process.padding(toLength: 28, withPad: " ", startingAt: 0)) \(offender.breakdown)")
        }
    }

    for accessoryID in index.accessories {
        let origin = DiagnosticReportIndex.Origin.accessory(id: accessoryID)
        let entries = index.entries(from: origin)
        guard entries.count > 4 else { continue }
        print("\n  ACCESSORY \(accessoryID.prefix(16))… — \(entries.count) reports")
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.process, default: 0] += 1 }
        for (name, count) in counts.sorted(by: { $0.value > $1.value }).prefix(6) {
            print("    \(name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(count)")
        }
    }
    print("")
}
