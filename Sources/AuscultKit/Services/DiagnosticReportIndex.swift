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
        /// Which device the report actually came from.
        public var origin: Origin

        public var filename: String { (path as NSString).lastPathComponent }
    }

    /// Whose report this is.
    ///
    /// An iPhone's crash-log directory also carries reports proxied from paired
    /// accessories — most obviously an Apple Watch, which has no direct link to
    /// a Mac and forwards everything through its phone. Those live under
    /// `ProxiedDevice-<id>/` and must not be mixed in with the phone's own, or
    /// a watch app crashing repeatedly is reported as a phone problem.
    public enum Origin: Hashable, Sendable {
        case host
        case accessory(id: String)

        public var isHost: Bool { self == .host }

        public var label: String {
            switch self {
            case .host: "this device"
            case .accessory(let id): "paired accessory \(id.prefix(12))"
            }
        }
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
        /// Written when the battery runs flat. The richest single source for a
        /// drain investigation: it records the awake/standby split, which app
        /// was in the foreground, and every power assertion held at the moment
        /// the device died.
        case lowBattery = "Battery ran flat"
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

            // Reports forwarded from a paired accessory sit under
            // ProxiedDevice-<identifier>/.
            var origin = Origin.host
            if path.hasPrefix("ProxiedDevice-"),
               let firstComponent = path.split(separator: "/").first {
                origin = .accessory(id: String(firstComponent.dropFirst("ProxiedDevice-".count)))
            }

            entries.append(Entry(
                path: path,
                process: processName(from: filename, kind: kind),
                kind: kind,
                date: file.metadata.lastModDate.string.flatMap(FlexibleDate.parse),
                sizeBytes: Int(file.metadata.size.int ?? 0),
                origin: origin
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
        if lower.contains("lowbatterylog") { return .lowBattery }
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
    public func offenders(
        since cutoff: Date? = nil, origin: Origin = .host
    ) -> [Offender] {
        var byProcess: [String: Offender] = [:]
        for entry in entries where entry.kind.implicatesEnergy {
            guard entry.origin == origin else { continue }
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

    /// Apple's own indexing, analysis and sync daemons.
    ///
    /// After a reboot — or a large photo import — these rebuild indexes that
    /// can take hours on a device with tens of gigabytes of media. While they
    /// run, idle power draw is legitimately several times its resting value,
    /// and any drain measurement taken during that window measures the
    /// rebuild rather than the device's normal behaviour.
    static let maintenanceDaemons: Set<String> = [
        "photoanalysisd", "mediaanalysisd", "searchd", "searchtoold",
        "suggestd", "duetexpertd", "siriactionsd", "cloudd", "backupd",
        "spotlightknowledged", "knowledgeconstructiond", "assetsd",
        "biomesyncd", "corespotlightd", "mediaremoted",
    ]

    /// Maintenance daemons that have exceeded a resource limit recently.
    ///
    /// Presence here means a drain measurement is not measuring steady state.
    public func maintenanceInProgress(within window: TimeInterval = 3600) -> [String] {
        let cutoff = Date().addingTimeInterval(-window)
        let busy = entries.filter { entry in
            guard entry.kind.implicatesEnergy else { return false }
            guard let date = entry.date, date >= cutoff else { return false }
            return Self.maintenanceDaemons.contains(entry.process)
        }
        return Array(Set(busy.map(\.process))).sorted()
    }

    public func count(of kind: Kind, origin: Origin = .host) -> Int {
        entries.filter { $0.kind == kind && $0.origin == origin }.count
    }

    /// Accessories that have forwarded reports through this device.
    public var accessories: [String] {
        Array(Set(entries.compactMap { entry -> String? in
            if case .accessory(let id) = entry.origin { return id }
            return nil
        })).sorted()
    }

    public func entries(from origin: Origin) -> [Entry] {
        entries.filter { $0.origin == origin }
    }

    /// The most recent reports of a kind, newest first.
    public func recent(_ kind: Kind, limit: Int, origin: Origin = .host) -> [Entry] {
        entries.filter { $0.kind == kind && $0.origin == origin }
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


/// The identity and failure reason inside a modern `.ips` crash report.
///
/// Counting crashes says an app is unhealthy; the termination record says *why*,
/// and on a Watch the why is usually specific and fixable. A watchOS app killed
/// for "WatchConnectivity watchdog transgression" is being woken to process data
/// from its phone and overrunning a two-second CPU budget — a very different
/// problem from a plain crash, and one that costs battery every time.
public struct CrashReportSummary: Sendable {
    public var process: String
    public var bundleID: String?
    public var appVersion: String?
    /// Hardware identifier of the device the report came from, e.g. "Watch6,13".
    public var modelCode: String?
    /// OS train, e.g. "Watch OS 26.6".
    public var osTrain: String?
    public var osBuild: String?
    /// Termination namespace: CAROUSEL, JETSAM, SPRINGBOARD, DYLD…
    public var terminationNamespace: String?
    /// Human-readable reason, verbatim from the report.
    public var terminationDetail: String?
    public var exceptionType: String?
    public var signal: String?
    public var date: Date?

    /// One line describing the failure, for a report.
    public var reasonSummary: String? {
        if let detail = terminationDetail, !detail.isEmpty {
            // These details are often several sentences; keep the first.
            let firstSentence = detail.split(separator: ".").first.map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            return firstSentence.map { "\($0)." } ?? detail
        }
        if let namespace = terminationNamespace { return "terminated by \(namespace)" }
        if let exceptionType { return exceptionType }
        return nil
    }

    public static func parse(_ text: String) -> CrashReportSummary? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty, let headerData = lines[0].data(using: .utf8) else { return nil }
        let header = DynamicValue.parseJSON(headerData)

        var summary = CrashReportSummary(
            process: header.firstPresent("app_name", "name", "procName").string ?? "unknown"
        )
        summary.bundleID = header.bundleID.string
        summary.appVersion = header.app_version.string

        // The body is a second JSON document on the remaining lines.
        if lines.count > 1,
           let bodyData = lines.dropFirst().joined(separator: "\n").data(using: .utf8) {
            let body = DynamicValue.parseJSON(bodyData)
            summary.modelCode = body.modelCode.string
            summary.osTrain = body.osVersion.train.string
            summary.osBuild = body.osVersion.build.string
            summary.terminationNamespace = body.termination.namespace.string
            // `details` is an array of strings; the first carries the reason.
            summary.terminationDetail = body.termination.details.array.first?.string
                ?? body.termination.reasons.array.first?.string
            summary.exceptionType = body.exception.type.string
            summary.signal = body.exception.signal.string
            if summary.process == "unknown" {
                summary.process = body.procName.string ?? "unknown"
            }
        }
        return summary
    }
}

/// One `LowBatteryLog` report: the state of the device when the battery died.
///
/// This is the most informative artefact iOS produces for a drain complaint. It
/// records how long the device had been awake versus asleep, what was in the
/// foreground, and — most usefully — every *power assertion* being held, which
/// names the subsystems that were preventing sleep and for how long.
public struct LowBatteryLogReport: Sendable {
    /// A held power assertion: who held it, what for, and how long.
    public struct Assertion: Sendable {
        public var holder: String
        public var name: String
        public var heldSeconds: Double

        /// The display being on is by far the most expensive assertion, so it
        /// is worth distinguishing from the rest.
        public var isBacklight: Bool {
            name.contains("backlightActive") || name.contains("liveRendering")
        }
    }

    public var date: Date?
    public var awakeSeconds: Double?
    public var standbySeconds: Double?
    public var foregroundApps: [String]
    public var screenBrightness: Double?
    public var voltageMillivolts: Double?
    public var assertions: [Assertion]

    /// Share of total time the device was awake rather than in standby.
    ///
    /// The single most diagnostic number in the file. A phone left mostly idle
    /// sits under 15%; sustained figures above 30% mean the device is barely
    /// sleeping, which no battery can survive.
    public var awakePercent: Double? {
        guard let awakeSeconds, let standbySeconds, awakeSeconds + standbySeconds > 0
        else { return nil }
        return awakeSeconds / (awakeSeconds + standbySeconds) * 100
    }

    /// Longest continuous stretch the display was on.
    public var longestBacklightSeconds: Double? {
        assertions.filter(\.isBacklight).map(\.heldSeconds).max()
    }

    public static func parse(_ text: String) -> LowBatteryLogReport? {
        var report = LowBatteryLogReport(
            foregroundApps: [], assertions: []
        )
        var sawAnything = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)

            if line.hasPrefix("Date:") {
                report.date = Self.parseDate(Self.after("Date:", line))
                sawAnything = true
            } else if line.hasPrefix("Awake Time:") {
                report.awakeSeconds = Self.parseDuration(Self.after("Awake Time:", line))
                sawAnything = true
            } else if line.hasPrefix("Standby Time:") {
                report.standbySeconds = Self.parseDuration(Self.after("Standby Time:", line))
            } else if line.hasPrefix("Foreground Applications:") {
                report.foregroundApps = Self.after("Foreground Applications:", line)
                    .split(separator: " ")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else if line.hasPrefix("Screen Brightness:") {
                report.screenBrightness = Double(Self.after("Screen Brightness:", line))
            } else if line.hasPrefix("Voltage:") {
                report.voltageMillivolts = Double(
                    Self.after("Voltage:", line)
                        .replacingOccurrences(of: " mV", with: "")
                        .trimmingCharacters(in: .whitespaces)
                )
            } else if let assertion = Self.parseAssertion(line) {
                report.assertions.append(assertion)
                sawAnything = true
            }
        }
        return sawAnything ? report : nil
    }

    /// `holder: assertion-name\tKIND == 255, held for HH:MM:SS`
    private static func parseAssertion(_ line: String) -> Assertion? {
        guard line.contains("held for"),
              line.contains("PreventUserIdleSystemSleep") || line.contains("SystemIsActive"),
              let colon = line.firstIndex(of: ":")
        else { return nil }

        let holder = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        guard !holder.isEmpty, !holder.contains(" ") else { return nil }

        let rest = String(line[line.index(after: colon)...])
        // The assertion name is separated from the state by a tab.
        let name = rest.split(separator: "\t").first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""

        guard let heldRange = rest.range(of: "held for ") else { return nil }
        let duration = rest[heldRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let seconds = parseDuration(duration) else { return nil }

        return Assertion(holder: holder, name: name, heldSeconds: seconds)
    }

    private static func after(_ marker: String, _ line: String) -> String {
        guard let range = line.range(of: marker) else { return "" }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    /// "30:35:54" or "30:35:54 (110154)" → seconds.
    static func parseDuration(_ raw: String) -> Double? {
        let clock = raw.split(separator: " ").first.map(String.init) ?? raw
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SSS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
