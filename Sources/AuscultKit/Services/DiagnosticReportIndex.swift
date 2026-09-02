import Foundation

/// iOS's own diagnostic reports, catalogued.
///
/// The device writes a report whenever a process exceeds a resource limit —
/// sustained CPU, excessive disk writes, too many wakeups — and whenever the
/// memory manager kills something. Each report is named for the process that
/// caused it, which means the *index alone* attributes misbehaviour to an app
/// without reading a single file.
///
/// That matters because iOS gives third parties no per-process energy API. The
/// power log has the real numbers but needs a sysdiagnose; this needs only a
/// directory listing, and answers the same question well enough to act on.
public struct DiagnosticReportIndex: Sendable {
    public struct Entry: Sendable, Hashable {
        /// Path within the crash-log domain, used to fetch the file.
        public var path: String
        /// The process the report is about, from the filename.
        public var process: String
        public var kind: Kind
        public var date: Date?
        public var sizeBytes: Int

        public var filename: String { (path as NSString).lastPathComponent }
    }

    /// Report categories, ordered by how strongly each implies energy use.
    public enum Kind: String, Sendable, CaseIterable {
        /// Sustained CPU over the limit. The strongest available energy signal.
        case cpuResource = "CPU exhaustion"
        /// Excessive wakeups — expensive because each one denies deep sleep.
        case wakeupsResource = "Excessive wakeups"
        /// Heavy disk writes. Costs energy and wears the flash.
        case diskWritesResource = "Excessive disk writes"
        /// Killed under memory pressure.
        case jetsam = "Memory kill"
        /// Kernel panic.
        case panic = "Kernel panic"
        /// System-wide stack sample, taken when the device is struggling.
        case stackshot = "Stackshot"
        /// Apple's daily analytics submission. Large; not parsed.
        case analytics = "Daily analytics"
        case crash = "Crash"

        /// Weight used to rank offenders. A minute of pegged CPU costs far more
        /// energy than a burst of disk writes, so they must not count equally.
        public var energyWeight: Double {
            switch self {
            case .cpuResource: 10
            case .wakeupsResource: 4
            case .diskWritesResource: 2
            case .jetsam: 1
            default: 0
            }
        }

        /// Does this kind implicate a process in power consumption?
        public var implicatesEnergy: Bool { energyWeight > 0 }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// Build the index from a `crashLogIndex` response.
    public static func parse(_ listing: DynamicValue) -> DiagnosticReportIndex {
        var files = listing.files.array
        if files.isEmpty { files = listing.search(forKey: "files").array }

        var entries: [Entry] = []
        for file in files {
            // Directories carry no report.
            if file.resources.isDirectory.bool == true { continue }
            guard let path = file.firstPresent("relativePath", "path", "name").string
            else { continue }

            let filename = (path as NSString).lastPathComponent
            guard let kind = classify(filename) else { continue }

            entries.append(Entry(
                path: path,
                process: processName(from: filename, kind: kind),
                kind: kind,
                date: file.metadata.lastModDate.string.flatMap(FlexibleDate.parse),
                sizeBytes: Int(file.metadata.size.int ?? 0)
            ))
        }
        return DiagnosticReportIndex(entries: entries)
    }

    static func classify(_ filename: String) -> Kind? {
        let lower = filename.lowercased()
        // Order matters: "cpu_resource" also contains "resource".
        if lower.contains("cpu_resource") { return .cpuResource }
        if lower.contains("wakeups_resource") { return .wakeupsResource }
        if lower.contains("diskwrites_resource") { return .diskWritesResource }
        if lower.contains("jetsam") { return .jetsam }
        if lower.contains("panic") { return .panic }
        if lower.hasPrefix("stacks-") { return .stackshot }
        if lower.hasPrefix("analytics-") { return .analytics }
        if lower.hasSuffix(".ips") || lower.hasSuffix(".crash") { return .crash }
        return nil
    }

    /// Extract the process name from a report filename.
    ///
    /// Reports are named `<Process>.<kind>-<timestamp>.ips`, or plain
    /// `<Process>-<timestamp>.ips` for crashes. Jetsam reports are named for
    /// the event rather than the victim, so they carry no process here — the
    /// victim is inside the file.
    static func processName(from filename: String, kind: Kind) -> String {
        var name = filename
        for suffix in [".ips.ca.synced", ".ips.synced", ".ips.ca", ".ips", ".crash", ".panic"] {
            if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)); break }
        }
        // Strip the trailing timestamp.
        if let range = name.range(of: #"-\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) {
            name = String(name[name.startIndex..<range.lowerBound])
        }
        // Strip the report-kind suffix.
        for marker in [".cpu_resource", ".wakeups_resource", ".diskwrites_resource"] {
            if name.hasSuffix(marker) { name = String(name.dropLast(marker.count)) }
        }
        // Trailing ".000" style sequence numbers.
        name = name.replacingOccurrences(
            of: #"\.\d+$"#, with: "", options: .regularExpression
        )
        return name.isEmpty ? filename : name
    }

    /// Report kinds whose filename names the *event* rather than a culprit.
    ///
    /// A jetsam report is called `JetsamEvent-<date>`; the process that was
    /// killed is recorded inside the file. Ranking on the filename would put a
    /// non-existent process called "JetsamEvent" at the top of the list.
    static let nonAttributableNames: Set<String> = ["JetsamEvent", "JetsamEvent-Bg", "stacks"]

    /// Processes ranked by how strongly the reports implicate them in energy use.
    public func offenders(since cutoff: Date? = nil) -> [Offender] {
        var byProcess: [String: Offender] = [:]
        for entry in entries where entry.kind.implicatesEnergy {
            if Self.nonAttributableNames.contains(entry.process) { continue }
            if let cutoff, let date = entry.date, date < cutoff { continue }
            var offender = byProcess[entry.process]
                ?? Offender(process: entry.process, counts: [:], score: 0, mostRecent: nil)
            offender.counts[entry.kind, default: 0] += 1
            offender.score += entry.kind.energyWeight
            if let date = entry.date, offender.mostRecent.map({ date > $0 }) ?? true {
                offender.mostRecent = date
            }
            byProcess[entry.process] = offender
        }
        return byProcess.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.process < $1.process
        }
    }

    public struct Offender: Sendable {
        public var process: String
        public var counts: [Kind: Int]
        public var score: Double
        public var mostRecent: Date?

        public var total: Int { counts.values.reduce(0, +) }

        /// "14 excessive disk writes, 2 CPU exhaustion"
        public var breakdown: String {
            counts.sorted { $0.key.energyWeight > $1.key.energyWeight }
                .map { "\($0.value) × \($0.key.rawValue.lowercased())" }
                .joined(separator: ", ")
        }
    }

    public func count(of kind: Kind) -> Int {
        entries.filter { $0.kind == kind }.count
    }

    /// The most recent reports of a kind, newest first.
    public func recent(_ kind: Kind, limit: Int) -> [Entry] {
        entries.filter { $0.kind == kind }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
}

/// One parsed resource-exhaustion report.
public struct ResourceReport: Sendable {
    public var process: String
    public var bundleID: String?
    public var appVersion: String?
    public var event: String?
    /// The verbatim limit line, e.g. "90 seconds cpu time over 97 seconds
    /// (93% cpu average), exceeding limit of 50% cpu over 180 seconds".
    public var detail: String?
    public var cpuSecondsUsed: Double?
    public var cpuAveragePercent: Double?
    public var durationSeconds: Double?
    public var date: Date?
    /// Frames of the heaviest stack, if present.
    public var heaviestStack: [String]

    /// Parse an `.ips` report: a JSON first line, then a plain-text body.
    ///
    /// Only the header keys and a handful of body lines are read. The body's
    /// shape differs per report type and changes between releases, so anything
    /// not found is simply absent rather than fatal.
    public static func parse(_ text: String) -> ResourceReport? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !lines.isEmpty else { return nil }

        var report = ResourceReport(process: "unknown", heaviestStack: [])

        // First line is a JSON metadata blob.
        if let headerData = lines[0].data(using: .utf8) {
            let header = DynamicValue.parseJSON(headerData)
            report.process = header.firstPresent("app_name", "name", "procName").string ?? "unknown"
            report.bundleID = header.bundleID.string
            report.appVersion = header.app_version.string
            if let ms = header.duration_ms.double { report.durationSeconds = ms / 1000 }
            if let stamp = header.timestamp.string {
                report.date = Self.parseReportDate(stamp)
            }
            lines.removeFirst()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Event:") {
                report.event = Self.value(after: "Event:", in: trimmed)
            } else if trimmed.hasPrefix("CPU:") || trimmed.hasPrefix("Disk Writes:")
                        || trimmed.hasPrefix("Wakeups:") {
                report.detail = Self.value(after: ":", in: trimmed)
                // "90 seconds cpu time over 97 seconds (93% cpu average)"
                if let seconds = Self.firstNumber(in: trimmed, before: "seconds") {
                    report.cpuSecondsUsed = seconds
                }
                if let percent = Self.firstNumber(in: trimmed, before: "%") {
                    report.cpuAveragePercent = percent
                }
            } else if trimmed.hasPrefix("CPU used:") {
                report.cpuSecondsUsed = Self.firstNumber(in: trimmed, before: "s")
                    ?? report.cpuSecondsUsed
            } else if trimmed.hasPrefix("Heaviest stack for the target process:") {
                continue
            } else if report.detail != nil, trimmed.hasPrefix("Command:") {
                report.process = Self.value(after: "Command:", in: trimmed) ?? report.process
            }
        }

        // The heaviest stack is the run of indented frames after its header.
        if let headerIndex = lines.firstIndex(where: {
            $0.contains("Heaviest stack for the target process")
        }) {
            report.heaviestStack = lines.dropFirst(headerIndex + 1)
                .prefix { $0.hasPrefix("  ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }

        return report
    }

    private static func value(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// First number appearing before `keyword` on the line.
    private static func firstNumber(in line: String, before keyword: String) -> Double? {
        guard let keywordRange = line.range(of: keyword) else { return nil }
        let prefix = line[line.startIndex..<keywordRange.lowerBound]
        let matches = prefix.matches(of: #/([0-9]+(?:\.[0-9]+)?)/#)
        return matches.last.flatMap { Double($0.output.1) }
    }

    private static func parseReportDate(_ raw: String) -> Date? {
        // "2026-08-27 03:23:19.00 +0100"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
