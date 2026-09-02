import Foundation

/// Client for `com.apple.mobile.diagnostics_relay`.
///
/// This is where the numbers that matter live. The relay exposes the device's
/// own IORegistry, which means the same battery gas-gauge registers, NAND
/// lifetime counters, and thermal sensors that Apple's internal tooling reads.
/// Nothing else reachable from a Mac gives you cycle count or raw capacity.
///
/// The relay speaks the same length-prefixed plist framing as lockdown, and its
/// request vocabulary has been stable across many major releases — but the
/// *contents* of the IORegistry move constantly. That's why callers search the
/// returned tree by key rather than walking a fixed path.
final class DiagnosticsRelay {
    static let serviceName = "com.apple.mobile.diagnostics_relay"
    /// The older name, still what some devices advertise.
    static let legacyServiceName = "com.apple.iosdiagnostics.relay"

    private let stream: ByteStream

    init(stream: ByteStream) { self.stream = stream }

    /// Open the relay, trying the modern service name then the legacy one.
    static func open(on client: LockdownClient) throws -> DiagnosticsRelay {
        do {
            return DiagnosticsRelay(stream: try client.startService(serviceName))
        } catch {
            // A device that doesn't advertise the modern name may still have
            // the old one; only report the original failure if both miss.
            if let legacy = try? client.startService(legacyServiceName) {
                return DiagnosticsRelay(stream: legacy)
            }
            throw error
        }
    }

    // MARK: Requests

    /// Dump an IORegistry subtree.
    ///
    /// `entryName` matches a named node, `entryClass` matches by class, and
    /// `plane` selects which registry plane to walk. Passing none dumps the
    /// whole registry, which is large but occasionally the only way to find
    /// something a new OS version has moved.
    func ioRegistry(
        entryName: String? = nil,
        entryClass: String? = nil,
        plane: String? = nil
    ) throws -> DynamicValue {
        var body: [String: Any] = ["Request": "IORegistry"]
        if let entryName { body["EntryName"] = entryName }
        if let entryClass { body["EntryClass"] = entryClass }
        if let plane { body["CurrentPlane"] = plane }
        return try send(body).Diagnostics
    }

    /// Query MobileGestalt keys. Note that iOS restricts which keys an
    /// unprivileged caller may read, and the allowed set shrinks over time;
    /// unreadable keys come back absent rather than failing the request.
    func mobileGestalt(keys: [String]) throws -> DynamicValue {
        try send(["Request": "MobileGestalt", "MobileGestaltKeys": keys]).Diagnostics
    }

    /// Built-in diagnostic bundles. Availability varies by device.
    func builtin(_ kind: Builtin) throws -> DynamicValue {
        try send(["Request": kind.rawValue]).Diagnostics
    }

    enum Builtin: String {
        case all = "All"
        case wifi = "WiFi"
        case gasGauge = "GasGauge"
        case nand = "NAND"
        case hdmi = "HDMI"
    }

    /// The battery gas gauge, tried by every route the device might offer.
    ///
    /// Route order is deliberate and was established by measurement, not
    /// assumption. On iOS 27 the purpose-built `GasGauge` request has been
    /// reduced to two fields (`CycleCount` and a rounded `FullChargeCapacity`),
    /// while the `AppleSmartBattery` IORegistry node still carries the full
    /// picture: design capacity, nominal and full charge capacity, cell serial,
    /// voltage, adapter details, and shutdown history. So we ask the registry
    /// first and fold the builtin in as a supplement, rather than stopping at
    /// the first route that returns anything.
    func batteryGauge() throws -> DynamicValue {
        var merged: [String: Any] = [:]
        var lastError: Error?

        // 1. Named IORegistry nodes, richest first. Names differ by hardware
        //    generation, so try each.
        for name in ["AppleSmartBattery", "AppleARMPMUCharger", "battery"] {
            do {
                let tree = try ioRegistry(entryName: name)
                if let dict = tree.raw as? [String: Any], !dict.isEmpty {
                    merged.merge(dict) { existing, _ in existing }
                    break
                }
            } catch { lastError = error }
        }

        // 2. By class, which survives node renames.
        if merged.isEmpty {
            for cls in ["IOPMPowerSource", "AppleSmartBattery"] {
                do {
                    let tree = try ioRegistry(entryClass: cls)
                    if let dict = tree.raw as? [String: Any], !dict.isEmpty {
                        merged.merge(dict) { existing, _ in existing }
                        break
                    }
                } catch { lastError = error }
            }
        }

        // 3. The builtin request. Thin on current releases but it is the only
        //    route on some older devices, and it costs one round trip.
        if let gauge = try? builtin(.gasGauge), let dict = gauge.raw as? [String: Any] {
            merged.merge(dict) { existing, _ in existing }
        }

        guard !merged.isEmpty else {
            if let lastError { throw lastError }
            throw RelayError.noData("battery gas gauge")
        }
        return DynamicValue(merged)
    }

    /// NAND lifetime and wear statistics.
    func nandStatistics() throws -> DynamicValue {
        if let nand = try? builtin(.nand), nand.exists, !nand.dictionary.isEmpty {
            return nand
        }
        for cls in ["IOFlashControllerNVMe", "AppleANS3NVMeController", "IONVMeController"] {
            if let tree = try? ioRegistry(entryClass: cls), tree.exists, !tree.dictionary.isEmpty {
                return tree
            }
        }
        throw RelayError.noData("NAND statistics")
    }

    func wifiDiagnostics() throws -> DynamicValue {
        try builtin(.wifi)
    }

    /// Ask the relay to shut down cleanly. Leaving it open is harmless but the
    /// device logs a disconnect error, which pollutes the very logs we read.
    func goodbye() {
        _ = try? send(["Request": "Goodbye"])
        stream.close()
    }

    // MARK: Framing

    private func send(_ body: [String: Any]) throws -> DynamicValue {
        let payload = try PropertyListSerialization.data(
            fromPropertyList: body, format: .xml, options: 0
        )
        var frame = Data()
        frame.appendBE(UInt32(payload.count))
        frame.append(payload)
        try stream.write(frame)

        let header = try stream.readExactly(4)
        let length = header.readBE(at: 0)
        // The full IORegistry can legitimately run to several megabytes.
        guard length > 0, length < 64 * 1024 * 1024 else {
            throw RelayError.badFraming(length: Int(length))
        }
        let responseData = try stream.readExactly(Int(length))
        let reply = DynamicValue.parsePlist(responseData)

        guard let status = reply.Status.string else {
            throw RelayError.badReply
        }
        guard status.caseInsensitiveCompare("Success") == .orderedSame else {
            throw RelayError.requestFailed(
                (body["Request"] as? String) ?? "request", status: status
            )
        }
        return reply
    }

    enum RelayError: LocalizedError {
        case badFraming(length: Int)
        case badReply
        case requestFailed(String, status: String)
        case noData(String)

        var errorDescription: String? {
            switch self {
            case .badFraming(let l):
                "diagnostics relay sent an implausible frame length (\(l))"
            case .badReply:
                "diagnostics relay reply had no Status field"
            case .requestFailed(let r, let s):
                "diagnostics relay rejected \(r): \(s)"
            case .noData(let what):
                "the device exposed no \(what) by any known route"
            }
        }
    }
}
