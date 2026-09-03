import Foundation

public extension DiagnosticReport {
    /// Stable machine-readable form. Versioned so downstream tooling can adapt.
    func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Plain-text report for the terminal and for pasting into tickets.
    func textReport(useColor: Bool = false) -> String {
        var out = ""
        let rule = String(repeating: "─", count: 68)

        func paint(_ s: String, _ v: Verdict) -> String {
            guard useColor else { return s }
            let code = switch v {
            case .pass: "32"; case .warn: "33"; case .fail: "31"
            case .error: "35"; case .info: "0"; default: "90"
            }
            return "\u{1B}[\(code)m\(s)\u{1B}[0m"
        }

        out += "\(rule)\n"
        out += "  \(device.displayName)\n"
        out += "  \(device.marketingName ?? device.productType ?? "unknown model") · \(device.osDescription)\n"
        if device.isPrereleaseOS { out += "  prerelease build\n" }
        out += "\(rule)\n"
        out += "  Verdict   \(paint("\(overallVerdict.symbol) \(overallVerdict.rawValue.uppercased())", overallVerdict))\n"
        out += "  Started   \(startedAt.formatted(date: .abbreviated, time: .standard))\n"
        out += "  Duration  \(String(format: "%.1fs", duration))\n"
        out += "\(rule)\n\n"

        for section in populatedSections {
            out += "\(section.rawValue.uppercased())\n"
            for r in results(in: section) {
                out += "  \(paint(r.verdict.symbol, r.verdict)) \(r.title) — \(r.summary)\n"
                if let d = r.diagnosticDetail {
                    out += "      ↳ \(d)\n"
                }
                for m in r.metrics {
                    let mark = m.verdict == .info ? " " : m.verdict.symbol
                    var line = "      \(paint(mark, m.verdict)) \(m.label): \(m.formattedValue)"
                    if let n = m.note { line += "  (\(n))" }
                    out += line + "\n"
                    // State the threshold a graded value was judged against.
                    if let expectation = m.expectation, m.verdict != .info {
                        out += "          expected: \(expectation)\n"
                    }
                    // Grouped values print as a small tree rather than a blob.
                    if case .grouped(let groups) = m.value {
                        for group in groups {
                            out += "          \(group.owner) — \(group.summary)\n"
                            for entry in group.entries {
                                out += "              \(entry)\n"
                            }
                        }
                    }
                }
                out += "\n"
            }
        }

        // Coverage matters as much as the findings: the reader needs to know
        // what wasn't measured.
        let unmeasured = self.unmeasured
        if !unmeasured.isEmpty {
            out += "NOT MEASURED\n"
            for r in unmeasured {
                out += "  \(r.verdict.symbol) \(r.title): \(r.summary)\n"
            }
            out += "\n"
        }

        out += "\(rule)\n"
        out += "  Host      macOS \(hostInfo.macOSVersion)"
        if let d = hostInfo.devicectlVersion { out += " · devicectl \(d)" }
        if let c = hostInfo.cfgutilVersion { out += " · \(c)" }
        out += "\n  Auscult   \(hostInfo.auscultVersion)\n"
        out += "  Coverage  \(capabilities.count) capabilities resolved\n"
        out += "\(rule)\n"
        return out
    }

    /// One-line-per-metric CSV, for diffing two runs of the same device.
    func csvReport() -> String {
        var rows = ["section,probe,metric,label,value,unit,verdict,note"]
        func esc(_ s: String?) -> String {
            guard let s, !s.isEmpty else { return "" }
            return s.contains(where: { ",\"\n".contains($0) })
                ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
                : s
        }
        for r in results {
            if r.metrics.isEmpty {
                rows.append([r.section.rawValue, r.probeID, "", esc(r.title), "",
                             "", r.verdict.rawValue, esc(r.summary)].joined(separator: ","))
            }
            for m in r.metrics {
                rows.append([
                    r.section.rawValue, r.probeID, m.id, esc(m.label),
                    esc(m.value.description), esc(m.unit), m.verdict.rawValue, esc(m.note),
                ].joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Counts by verdict, for headline display.
    var tally: [Verdict: Int] {
        var t: [Verdict: Int] = [:]
        for r in results { t[r.verdict, default: 0] += 1 }
        return t
    }
}
