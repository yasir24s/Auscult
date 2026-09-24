import Foundation
import UIKit
import Darwin

// MARK: - RAM under pressure

/// Pushes the whole device into memory pressure, then proves every byte held.
///
/// `memory.info` only reads the installed figure. This test takes most of the
/// memory an app is allowed, which forces iOS to compress everything else —
/// and evict it if compression is not enough — and records how the *system* responds — the pressure levels it signals
/// and how much was held when it did. Then it reads the whole allocation back.
///
/// Three constraints shape it:
///
/// - **An app cannot exceed its own jetsam limit.** Crossing it gets the process
///   killed outright, taking the Mac link and the result with it. The limit is
///   re-read before every chunk, and allocation stops `safetyMargin` short.
/// - **Allocating is not enough — pages must be written.** Untouched pages are
///   handed out lazily and cost nothing, and zeros compress to nearly nothing, so
///   neither creates real pressure. Each chunk is filled with incompressible
///   pseudo-random data.
/// - **That data is also the integrity check.** The generator is seeded per
///   chunk, so the sequence can be regenerated and compared word for word after
///   the peak. A mismatch means RAM — or the compressor, under load — returned
///   something other than what was written. That is the one hardware verdict
///   here; the pressure figures are measurements, not grades.
struct MemoryPressureTest: AgentTest {
    private static let chunkBytes = 64 << 20                 // 64 MiB per step
    private static let safetyMargin: Int64 = 512 << 20       // headroom kept below our own limit
    private static let capFraction = 0.85                    // never ask for more than this share of RAM
    private static let fillBudget: TimeInterval = 30
    private static let holdSeconds: UInt64 = 2

    var descriptor: AgentTestDescriptor {
        // requiresInteraction: it needs consent, because iOS may close the
        // person's other apps. (On an iPad Air M3 it reached critical and iOS
        // coped by compressing alone — no jetsam report — but that is not
        // guaranteed on a device with less headroom.) That also keeps it out of Run All, which must
        // never evict someone's apps without asking.
        AgentTestDescriptor(id: "memory.pressure", title: "RAM Under Pressure",
                            section: "Compute", requiresInteraction: true,
                            estimatedSeconds: 30)
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        context.progress(0.02, "Asking before filling memory")
        let answer = await context.askUser(UserPrompt(
            message: "This fills most of the device's memory to put it under pressure. "
                + "iOS may close other apps to make room — unsaved work in them could be lost.",
            confirmTitle: "Start", rejectTitle: "Cancel"
        ))
        guard answer == .confirmed else {
            return result(.skipped, answer == .rejected
                ? "Cancelled — nothing was allocated"
                : "Not started — nobody confirmed on the device")
        }

        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        let allowanceAtStart = Int64(os_proc_available_memory())
        let cap = Int64(Double(physical) * Self.capFraction)
        let before = VMSnapshot.take()

        // System-wide pressure, as the kernel's memorystatus level reports it —
        // the signal that says the *device* is struggling, not merely this app.
        let log = PressureLog()
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .global(qos: .userInitiated))
        source.setEventHandler { log.record(source.data) }
        source.activate()
        // UIKit's warning is per-app: it fires as *this* process nears its own
        // limit. Recorded separately so the two are never confused.
        let observer = await MainActor.run {
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil, queue: nil) { _ in log.recordAppWarning() }
        }

        var chunks: [UnsafeMutableRawPointer] = []
        func releaseAll() {
            for c in chunks { munmap(c, Self.chunkBytes) }
            chunks.removeAll()
        }
        // Released on every exit path, including cancellation and throws —
        // a leaked multi-gigabyte allocation would leave the device crippled.
        defer {
            releaseAll()
            source.cancel()
            NotificationCenter.default.removeObserver(observer)
        }

        // ---- Fill -------------------------------------------------------------
        var held: Int64 = 0
        var lowestFree = before?.free ?? 0
        var highestCompressed = before?.compressed ?? 0
        let target = min(cap, allowanceAtStart > 0 ? allowanceAtStart - Self.safetyMargin : cap)
        let fillStart = Date()
        var stopReason = "it reached the test's own ceiling"

        while true {
            if Task.isCancelled { throw CancellationError() }
            if log.sawCritical {
                stopReason = "iOS signalled critical memory pressure"; break
            }
            let allowance = Int64(os_proc_available_memory())
            // Zero means iOS gave no figure (it does on some configurations);
            // fall back on the cap and the pressure signal alone rather than
            // treating it as "no memory left".
            if allowance > 0, allowance < Self.safetyMargin + Int64(Self.chunkBytes) {
                stopReason = "it reached this app's memory limit"; break
            }
            if held + Int64(Self.chunkBytes) > cap {
                stopReason = "it reached the test's own ceiling (\(Int(Self.capFraction * 100))% of RAM)"; break
            }
            if Date().timeIntervalSince(fillStart) > Self.fillBudget {
                stopReason = "it ran out of time"; break
            }
            let p = mmap(nil, Self.chunkBytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
            guard let p, p != MAP_FAILED else {
                stopReason = "the system refused to hand out more memory"; break
            }
            Self.fill(p, seed: Self.seed(chunks.count))
            chunks.append(p)
            held += Int64(Self.chunkBytes)
            log.held = held

            if let now = VMSnapshot.take() {
                lowestFree = min(lowestFree, now.free)
                highestCompressed = max(highestCompressed, now.compressed)
            }
            let fraction = target > 0 ? min(Double(held) / Double(target), 1) : 0.5
            context.progress(0.05 + fraction * 0.55,
                             "Holding \(Self.gb(held)) of memory")
        }
        let fillSeconds = Date().timeIntervalSince(fillStart)

        guard held > 0 else {
            return result(.error, "Could not allocate any memory to test",
                          detail: stopReason)
        }

        // ---- Hold -------------------------------------------------------------
        // Give iOS a moment at the peak: evictions and compression lag the
        // allocation, and the lowest free-memory figure arrives after it.
        context.progress(0.62, "Holding at peak while iOS responds")
        for _ in 0..<(Self.holdSeconds * 4) {
            if Task.isCancelled { throw CancellationError() }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let now = VMSnapshot.take() {
                lowestFree = min(lowestFree, now.free)
                highestCompressed = max(highestCompressed, now.compressed)
            }
        }

        // ---- Verify -----------------------------------------------------------
        var badWords = 0
        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            badWords += Self.verify(chunk, seed: Self.seed(index))
            context.progress(0.65 + Double(index + 1) / Double(chunks.count) * 0.28,
                             "Reading back \(Self.gb(Int64(index + 1) * Int64(Self.chunkBytes)))")
        }
        let totalWords = chunks.count * (Self.chunkBytes / 8)

        // ---- Release and recover ------------------------------------------------
        releaseAll()
        context.progress(0.95, "Released — watching the device recover")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let after = VMSnapshot.take()

        // ---- Report -----------------------------------------------------------
        let events = log.snapshot()
        let reached = events.contains { $0.level == .critical } ? "critical"
            : events.contains { $0.level == .warning } ? "warning" : "none"

        var metrics: [AgentMetric] = [
            .flag("integrity", "Every byte read back intact", badWords == 0,
                  shouldBe: true, severityIfNot: .fail,
                  note: badWords == 0
                    ? "\(Self.gb(held)) of incompressible data written, held under pressure, and read back unchanged"
                    : "\(badWords) of \(totalWords) words came back different — the RAM, or the memory "
                      + "compressor under load, returned the wrong data"),
            .bytes("held", "Memory held at peak", held, note: "stopped because \(stopReason)"),
            .reading("pressure", "Device-wide pressure reached", reached,
                     note: reached == "none"
                        ? "this app hit its own limit before iOS signalled system pressure — the device had headroom"
                        : "iOS told every process the system was short of memory"),
        ]
        if let w = events.first(where: { $0.level == .warning }) {
            metrics.append(.bytes("atWarning", "Held when iOS signalled warning", w.held,
                                  note: String(format: "after %.1f s", w.at)))
        }
        if let c = events.first(where: { $0.level == .critical }) {
            metrics.append(.bytes("atCritical", "Held when iOS signalled critical", c.held,
                                  note: String(format: "after %.1f s", c.at)))
        }
        if log.appWarnings > 0 {
            metrics.append(.number("appWarnings", "Memory warnings sent to this app",
                                   Double(log.appWarnings),
                                   note: "per-app, as this process neared its own limit"))
        }
        metrics.append(.bytes("allowance", "This app's memory limit at start", allowanceAtStart,
                              note: "iOS's per-app ceiling — no app can hold more than this"))
        if let before {
            metrics.append(.bytes("freeBefore", "Device free memory before", before.free))
            metrics.append(.bytes("freePeak", "Device free memory at peak", lowestFree))
            if let after {
                metrics.append(.bytes("freeAfter", "Device free memory after release", after.free,
                                      note: "recovers as pages are handed back"))
            }
            metrics.append(.bytes("compressedBefore", "Compressed memory before", before.compressed))
            metrics.append(.bytes("compressedPeak", "Compressed memory at peak", highestCompressed,
                                  note: "memory the compressor squeezed — other processes' and this test's own idle pages"))
        } else {
            metrics.append(.absent("deviceMemory", "Device-wide memory figures",
                                   why: "iOS did not return system memory statistics"))
        }
        if fillSeconds > 0 {
            metrics.append(.number("fillRate", "Write speed while filling",
                                   Double(held) / fillSeconds / 1e9, unit: "GB/s"))
        }

        let summary: String
        if badWords > 0 {
            summary = "\(badWords) memory errors after filling \(Self.gb(held)) — the RAM may be faulty"
        } else if reached == "none" {
            summary = "Held \(Self.gb(held)) without pushing the device into pressure — every byte read back intact"
        } else {
            let at = events.first(where: { $0.level == .warning })?.held
                ?? events.first(where: { $0.level == .critical })?.held ?? held
            summary = "Held \(Self.gb(held)); iOS signalled \(reached) pressure at \(Self.gb(at)) — every byte read back intact"
        }
        return result(rollup(metrics), summary, metrics: metrics)
    }

    // MARK: Pattern

    /// Distinct, never-zero seed per chunk, so a chunk that ends up holding
    /// another chunk's data — an addressing fault — fails verification too.
    private static func seed(_ index: Int) -> UInt64 {
        (UInt64(index) &+ 1) &* 0x9E37_79B9_7F4A_7C15 ^ 0xD1B5_4A32_D192_ED03
    }

    /// xorshift64: cheap enough to run at memory speed, random enough that the
    /// compressor gets nowhere with it.
    private static func fill(_ p: UnsafeMutableRawPointer, seed: UInt64) {
        let n = chunkBytes / 8
        let w = p.bindMemory(to: UInt64.self, capacity: n)
        var x = seed
        for i in 0..<n {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            w[i] = x
        }
    }

    private static func verify(_ p: UnsafeMutableRawPointer, seed: UInt64) -> Int {
        let n = chunkBytes / 8
        let w = p.bindMemory(to: UInt64.self, capacity: n)
        var x = seed
        var bad = 0
        for i in 0..<n {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            if w[i] != x { bad += 1 }
        }
        return bad
    }

    private static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9)
    }
}

// MARK: - Device-wide memory statistics

/// Whole-device VM counters from the kernel — the view from outside this
/// process, which is what makes "device-wide" measurable rather than assumed.
private struct VMSnapshot {
    let free: Int64         // free + speculative: immediately usable
    let compressed: Int64   // pages the compressor holds, i.e. squeezed memory

    static func take() -> VMSnapshot? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = DeviceFacts.sysctlInt("hw.pagesize") ?? 16384
        return VMSnapshot(
            free: Int64(info.free_count + info.speculative_count) * page,
            compressed: Int64(info.compressor_page_count) * page
        )
    }
}

// MARK: - Pressure log

/// Written from the dispatch source's queue and UIKit's main thread, read by
/// the test — hence the lock.
private final class PressureLog: @unchecked Sendable {
    enum Level { case normal, warning, critical }
    struct Event { let level: Level; let held: Int64; let at: TimeInterval }

    private let lock = NSLock()
    private let start = Date()
    private var events: [Event] = []
    private var _held: Int64 = 0
    private var _appWarnings = 0

    var held: Int64 {
        get { lock.withLock { _held } }
        set { lock.withLock { _held = newValue } }
    }
    var appWarnings: Int { lock.withLock { _appWarnings } }
    var sawCritical: Bool { lock.withLock { events.contains { $0.level == .critical } } }

    func record(_ event: DispatchSource.MemoryPressureEvent) {
        let level: Level = event.contains(.critical) ? .critical
            : event.contains(.warning) ? .warning : .normal
        lock.withLock {
            events.append(Event(level: level, held: _held, at: Date().timeIntervalSince(start)))
        }
    }

    func recordAppWarning() { lock.withLock { _appWarnings += 1 } }

    func snapshot() -> [Event] { lock.withLock { events } }
}
