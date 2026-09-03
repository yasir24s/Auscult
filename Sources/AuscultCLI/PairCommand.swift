import Foundation
import AuscultKit

/// `auscult pair` — what can this Mac reach, and what would it take to reach more.
///
/// Devices with no USB port are only diagnosable once paired to this host, and
/// the failure modes are hard to tell apart from outside: not on the network,
/// not in Developer Mode, or simply not paired. Browsing Bonjour separates them.
func runPairCommand(session: DiagnosticSession) async {
    print("Devices CoreDevice already knows about:\n")
    let (devices, _) = await session.devices()
    for device in devices where !device.isSimulator {
        let reach = device.isReachable ? "reachable" : "not reachable now"
        print("  \(device.displayName)")
        print("      \(device.marketingName ?? device.productType ?? "?")  ·  \(device.osDescription)")
        print("      \(device.link.rawValue) · \(device.pairing.rawValue) · \(reach)")
    }
    if devices.filter({ !$0.isSimulator }).isEmpty { print("  (none)") }

    // Called out before the network browse, because someone who has just
    // plugged a charger in reasonably expects to see a device appear.
    let powerOnly = await PairingDiscovery.powerOnlyAccessories()
    if !powerOnly.isEmpty {
        print("\nAttached over USB but carrying no data:\n")
        for accessory in powerOnly {
            print("  \(accessory.productName)")
            print("      \(accessory.explanation)")
        }
    }

    print("\nBrowsing the local network for devices offering to pair…\n")
    let advertisers = await PairingDiscovery.browse(seconds: 6)

    if advertisers.isEmpty {
        print("  Nothing is advertising. Devices only advertise when unlocked and")
        print("  on the same network as this Mac.")
    }
    for advertiser in advertisers {
        print("  \(advertiser.likelyKind)")
        print("      host: \(advertiser.hostname ?? "unresolved")"
              + (advertiser.port.map { ":\($0)" } ?? ""))
        print("      via:  \(advertiser.service)")
    }

    let known = Set(devices.map { ($0.name ?? "").lowercased() })
    let watchSeen = advertisers.contains { $0.likelyKind == "Apple Watch" }
        || known.contains { $0.contains("watch") }

    print("""

    APPLE WATCH

    A Watch has no data port at all. Its magnetic charger is an induction
    coil: the cable enumerates on USB, but nothing is behind it, so plugging
    the Watch into a Mac can never produce a data connection.

    A Watch is therefore reached only over the network, and discovered through
    the iPhone it belongs to. The requirements are:

      1. The iPhone must be connected to this Mac and unlocked.
      2. The Watch must be unlocked and on the same Wi-Fi network.
      3. Developer Mode must be enabled on the Watch itself:
         Watch › Settings › Privacy & Security › Developer Mode.
         (The Watch app on the iPhone cannot set this; it is on the Watch.)
      4. Xcode › Window › Devices and Simulators — the Watch appears under its
         paired iPhone. Pair it there once.

    Status: \(watchSeen
        ? "a Watch is visible — try `auscult list` and run diagnostics against it."
        : "no Watch visible yet. Work through the four points above.")

    Even unpaired, the Watch's crash and resource reports are already readable:
    it forwards them through the iPhone, and `auscult run` reports them under
    'Paired Accessory Health'.
    """)
}
