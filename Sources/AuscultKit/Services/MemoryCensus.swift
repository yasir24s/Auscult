import Foundation

/// A full resident-memory census of the device.
///
/// Jetsam reports carry a complete process table — every process and its
/// resident page count — captured at the moment iOS killed something for
/// memory. That is a better census than any live query: it is precisely the
/// snapshot of the worst moment, which is what matters when the question is
/// what exhausted the RAM.
public struct MemoryCensus: Sendable {
    public struct Process: Sendable {
        public var name: String
        public var residentBytes: Int64
        /// `suspended`, `frontmost`, `daemon`, `idle`, `active`…
        public var states: [String]
        public var category: Category

        /// Suspended processes hold RAM without using CPU. They are the ones
        /// worth naming, because closing them frees memory at no cost.
        public var isSuspended: Bool { states.contains("suspended") }
    }

    /// Where a process's memory belongs, for grouping.
    public enum Category: String, Sendable, CaseIterable {
        case kernel = "Kernel"
        case userInterface = "System UI"
        case appleIntelligence = "Apple Intelligence & Siri"
        case media = "Media & photo processing"
        case systemDaemon = "Other system daemons"
        case thirdParty = "Apps"
    }

    /// Kernel-side accounting, in bytes.
    public struct Kernel: Sendable {
        public var wired: Int64 = 0
        public var active: Int64 = 0
        public var inactive: Int64 = 0
        public var free: Int64 = 0
        public var purgeable: Int64 = 0
        public var fileBacked: Int64 = 0
        public var anonymous: Int64 = 0
        /// Size of the compressed page store.
        public var compressor: Int64 = 0
    }

    public var date: Date?
    public var kernel: Kernel
    public var processes: [Process]
    public var pageSize: Int64

    public var totalResident: Int64 {
        processes.reduce(0) { $0 + $1.residentBytes }
    }

    public func total(of category: Category) -> Int64 {
        processes.filter { $0.category == category }.reduce(0) { $0 + $1.residentBytes }
    }

    public var suspendedTotal: Int64 {
        processes.filter(\.isSuspended).reduce(0) { $0 + $1.residentBytes }
    }

    /// Classify a process by name.
    ///
    /// Pattern-matched rather than table-driven: Apple renames these daemons
    /// freely between releases, and a name that falls through to
    /// "other system daemon" is a mild loss of grouping rather than a wrong
    /// answer.
    static func categorise(_ name: String) -> Category {
        if name == "kernel_task" { return .kernel }

        let intelligence = [
            "OnDeviceInference", "intelligenceflow", "assistantd", "siri",
            "AppleCentauri", "textunderstanding", "searchd", "searchtool",
            "knowledge", "proactive", "naturallanguage", "generativefunction",
        ]
        if intelligence.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
            return .appleIntelligence
        }

        let media = [
            "mediaanalysis", "photoanalysis", "assetsd", "cameracaptured",
            "mediaserver", "mediaplayback", "audiomxd", "videosubscriptions",
            "imagent", "photolibrary",
        ]
        if media.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
            return .media
        }

        let ui = ["SpringBoard", "backboardd", "WidgetRenderer", "chronod", "runningboardd"]
        if ui.contains(where: { name.hasPrefix($0) }) { return .userInterface }

        // Daemons conventionally end in 'd'; anything else with a capitalised
        // name is most likely an app bundle.
        if name.hasSuffix("d") && name.lowercased() == name { return .systemDaemon }
        if let first = name.first, first.isUppercase { return .thirdParty }
        return .systemDaemon
    }

    /// Parse a jetsam report body.
    public static func parse(_ text: String, date: Date?) -> MemoryCensus? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 1, let data = lines.dropFirst().joined(separator: "\n").data(using: .utf8)
        else { return nil }

        let body = DynamicValue.parseJSON(data)
        let status = body.memoryStatus
        let pageSize = status.pageSize.int ?? 16384
        let pages = status.memoryPages

        func bytes(_ key: String) -> Int64 {
            (pages[key].int ?? 0) * pageSize
        }

        var kernel = Kernel()
        kernel.wired = bytes("wired")
        kernel.active = bytes("active")
        kernel.inactive = bytes("inactive")
        kernel.free = bytes("free")
        kernel.purgeable = bytes("purgeable")
        kernel.fileBacked = bytes("fileBacked")
        kernel.anonymous = bytes("anonymous")
        kernel.compressor = (status.compressorSize.int ?? 0) * pageSize

        let processes = body.processes.array.compactMap { entry -> Process? in
            guard let name = entry.name.string else { return nil }
            let resident = (entry.rpages.int ?? 0) * pageSize
            return Process(
                name: name,
                residentBytes: resident,
                states: entry.states.stringList,
                category: categorise(name)
            )
        }
        guard !processes.isEmpty else { return nil }

        return MemoryCensus(
            date: date, kernel: kernel,
            processes: processes.sorted { $0.residentBytes > $1.residentBytes },
            pageSize: pageSize
        )
    }
}
