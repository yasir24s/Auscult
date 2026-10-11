import Foundation

/// Step-by-step trace of the deep handshake, for `auscult relay`.
///
/// The lockdown path has five distinct failure points (mux, pair record, TLS
/// identity, session, service) and they produce very similar symptoms from the
/// outside. Walking them one at a time with short timeouts is the difference
/// between a five-second diagnosis and guessing.
public enum LockdownDebug {
    /// - Parameter preferNetwork: force the network sighting even when a cable
    ///   is attached. Needed to prove the relay works unplugged *before* asking
    ///   someone to unplug, rather than discovering it does not afterwards.
    public static func trace(udid: String?, preferNetwork: Bool = false) async -> String {
        var log: [String] = []
        func step(_ s: String) { log.append(s) }

        do {
            let mux = UsbmuxClient()
            let all = try await BlockingIO.run { try mux.listDevices() }
            step("① usbmux ListDevices → \(all.count) sighting(s)")

            let candidates = udid == nil ? all : all.filter { $0.serialNumber == udid! }
            let ordered = preferNetwork
                ? (candidates.first(where: { !$0.isUSB }) ?? candidates.first)
                : (candidates.first(where: \.isUSB) ?? candidates.first)
            guard let device = ordered else {
                step("   no matching device — connect it over USB")
                return log.joined(separator: "\n")
            }
            step("   using deviceID \(device.deviceID) (\(device.connectionType)) \(device.serialNumber)")

            let record = try await BlockingIO.run { try mux.readPairRecord(udid: device.serialNumber) }
            step("② pair record → HostID \(record.hostID)")

            let identity = try HostIdentity.make(from: record)
            step("③ TLS identity → built")
            _ = identity

            step("④ opening tunnel to lockdown port 62078…")
            let deviceID = device.deviceID
            let serial = device.serialNumber
            let client = try await BlockingIO.run {
                try LockdownClient.connect(deviceID: deviceID, udid: serial, mux: mux)
            }
            step("   session established (TLS up)")

            // A cheap GetValue confirms the session really works before we
            // spend time on a service.
            if let productVersion = try? await BlockingIO.run({ try client.getValue(key: "ProductVersion").string }) ?? nil {
                step("⑤ GetValue ProductVersion → \(productVersion)")
            } else {
                step("⑤ GetValue ProductVersion → unavailable")
            }

            step("⑥ starting diagnostics relay…")
            let relay = try await BlockingIO.run { try DiagnosticsRelay.open(on: client) }
            step("   relay open")

            // Dump the gauge verbatim: the whole point is to learn the shape
            // this OS build actually returns.
            do {
                let t0 = Date()
                let gauge = try await BlockingIO.run { try relay.batteryGauge() }
                step("⑦ battery gauge → \(String(format: "%.2fs", Date().timeIntervalSince(t0)))")
                for line in flatten(gauge, indent: "     ") { step(line) }
            } catch {
                step("⑦ battery gauge → FAILED: \(error.localizedDescription)")
            }

            do {
                let t0 = Date()
                let nand = try await BlockingIO.run { try relay.nandStatistics() }
                step("⑧ NAND → \(String(format: "%.2fs", Date().timeIntervalSince(t0)))")
                for line in flatten(nand, indent: "     ").prefix(30) { step(line) }
            } catch {
                step("⑧ NAND → FAILED: \(error.localizedDescription)")
            }

            // AFC lives on the same session; show what it reports.
            do {
                let afc = try await BlockingIO.run { try AFCClient.open(on: client) }
                let info = try await BlockingIO.run { try afc.deviceInfo() }
                step("⑩ AFC device info → \(info.count) keys")
                for key in info.keys.sorted() {
                    step("     \(key) = \(info[key] ?? "")")
                }
                await BlockingIO.runIgnoringErrors { afc.close() }
            } catch {
                step("⑩ AFC → FAILED: \(error.localizedDescription)")
            }

            relay.goodbye()
            client.close()
            step("⑨ closed cleanly")
        } catch {
            step("✗ FAILED: \(error.localizedDescription)")
        }
        return log.joined(separator: "\n")
    }

    /// Dump an IORegistry node, by name or by class, so a new OS build's actual
    /// layout can be inspected rather than guessed at.
    public static func ioregistry(
        udid: String?, entryName: String?, entryClass: String?,
        preferNetwork: Bool = false
    ) async -> String {
        do {
            let mux = UsbmuxClient()
            let all = try await BlockingIO.run { try mux.listDevices() }
            let candidates = udid == nil ? all : all.filter { $0.serialNumber == udid! }
            let ordered = preferNetwork
                ? (candidates.first(where: { !$0.isUSB }) ?? candidates.first)
                : (candidates.first(where: \.isUSB) ?? candidates.first)
            guard let device = ordered else {
                return "no matching device attached over USB"
            }
            let deviceID = device.deviceID
            let serial = device.serialNumber

            let (client, relay) = try await BlockingIO.run { () -> (LockdownClient, DiagnosticsRelay) in
                let c = try LockdownClient.connect(deviceID: deviceID, udid: serial, mux: mux)
                return (c, try DiagnosticsRelay.open(on: c))
            }
            defer { relay.goodbye(); client.close() }

            let t0 = Date()
            let tree = try await BlockingIO.run {
                try relay.ioRegistry(entryName: entryName, entryClass: entryClass)
            }
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(t0))
            let target = entryName ?? entryClass ?? "(whole registry)"
            let lines = flatten(tree, indent: "  ")
            return "IORegistry \(target) → \(lines.count) lines in \(elapsed)\n"
                + lines.joined(separator: "\n")
        } catch {
            return "FAILED: \(error.localizedDescription)"
        }
    }

    /// Render a nested plist tree as indented `key = value` lines.
    private static func flatten(
        _ value: DynamicValue, indent: String, depth: Int = 0
    ) -> [String] {
        guard depth < 4 else { return ["\(indent)…"] }
        let dict = value.dictionary
        guard !dict.isEmpty else {
            return value.exists ? ["\(indent)\(value.string ?? "(opaque)")"] : []
        }
        var lines: [String] = []
        for key in dict.keys.sorted() {
            let child = dict[key]!
            let childDict = child.dictionary
            if childDict.isEmpty {
                // The dump is the kind of output that gets pasted into a bug
                // report, so it hides serials the same way the report does.
                let rendered = child.string.map {
                    Redaction.isSerialKey(key) ? Redaction.serial($0) : $0
                }
                    ?? child.double.map { String($0) }
                    ?? child.bool.map { $0 ? "true" : "false" }
                    ?? (child.array.isEmpty ? "(opaque)" : "[\(child.array.count) items]")
                lines.append("\(indent)\(key) = \(rendered)")
            } else {
                lines.append("\(indent)\(key):")
                lines.append(contentsOf: flatten(child, indent: indent + "  ", depth: depth + 1))
            }
        }
        return lines
    }
}
