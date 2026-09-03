import Foundation

/// Finds Apple devices advertising themselves for pairing on the local network.
///
/// Devices without a USB port — an Apple Watch, an Apple TV — can only be
/// reached over the network, and only once paired to this Mac. They advertise
/// over Bonjour, so browsing tells us what is *reachable* before any pairing is
/// attempted, which is the difference between "the Watch is not set up" and
/// "the Watch is not even on the network".
public enum PairingDiscovery {
    public struct Advertiser: Sendable {
        public var identifier: String
        public var hostname: String?
        public var port: Int?
        /// Bonjour service type it was found on.
        public var service: String

        /// Best guess at the device from its advertised hostname.
        public var likelyKind: String {
            let host = (hostname ?? "").lowercased()
            if host.contains("watch") { return "Apple Watch" }
            if host.contains("apple-tv") || host.contains("appletv") { return "Apple TV" }
            if host.contains("ipad") { return "iPad" }
            if host.contains("iphone") { return "iPhone" }
            if host.contains("vision") { return "Apple Vision Pro" }
            return "unknown"
        }
    }

    /// Service types Apple devices use to offer themselves to a host.
    static let services = [
        // Modern remote pairing, iOS 17 / watchOS 10 and later.
        "_remotepairing._tcp",
        // Classic wireless device link.
        "_apple-mobdev2._tcp",
    ]

    /// Browse for advertisers. Shells out to `dns-sd`, which is always present
    /// on macOS and avoids taking a Network.framework dependency here for what
    /// is a one-shot diagnostic query.
    public static func browse(seconds: TimeInterval = 6) async -> [Advertiser] {
        var found: [Advertiser] = []
        for service in services {
            guard let listing = try? await Shell.run(
                "/usr/bin/dns-sd", ["-t", String(Int(seconds)), "-B", service],
                timeout: seconds + 6
            ) else { continue }

            // Lines look like:
            //   <time>  Add  <flags> <if> local. <service>. <instance name>
            for line in listing.out.split(separator: "\n") {
                guard line.contains("Add"), line.contains(service) else { continue }
                let columns = line.split(separator: " ", omittingEmptySubsequences: true)
                guard let instance = columns.last.map(String.init), instance != service + "."
                else { continue }

                var advertiser = Advertiser(
                    identifier: instance, hostname: nil, port: nil, service: service
                )
                // Resolve for the hostname, which is what identifies the device.
                if let resolved = try? await Shell.run(
                    "/usr/bin/dns-sd", ["-t", "4", "-L", instance, service],
                    timeout: 12
                ) {
                    for resolvedLine in resolved.out.split(separator: "\n")
                    where resolvedLine.contains("can be reached at") {
                        let parts = resolvedLine.components(separatedBy: "can be reached at ")
                        if parts.count > 1 {
                            let endpoint = parts[1].trimmingCharacters(in: .whitespaces)
                            let pieces = endpoint.split(separator: ":")
                            advertiser.hostname = pieces.first.map(String.init)
                            advertiser.port = pieces.count > 1
                                ? Int(pieces[1].prefix { $0.isNumber }) : nil
                        }
                    }
                }
                if !found.contains(where: { $0.identifier == advertiser.identifier }) {
                    found.append(advertiser)
                }
            }
        }
        return found
    }
}
