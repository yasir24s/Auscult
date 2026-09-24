import Foundation

/// What battery figures mean, in plain language — shared so the device and the
/// Mac explain battery health in exactly the same words.
///
/// Every claim here is one Apple makes itself (support.apple.com/101575 and the
/// iPhone User Guide, "Understand your iPhone battery usage and health"):
///   - iPhone 14 and earlier: designed to keep 80% of original capacity at 500
///     complete charge cycles; Settings shows Maximum Capacity but no cycle count.
///   - iPhone 15 and later: 80% at 1000 cycles; Settings shows both.
///   - iPad: 80% at 1000 cycles.
/// Nothing is said about replacement thresholds Apple does not publish.
public enum BatteryGuide {
    public struct Rating: Equatable, Sendable {
        /// Complete charge cycles Apple designs the battery to reach at 80%.
        public let ratedCycles: Int
        /// Whether Settings shows a cycle count on this model. nil = not
        /// documented, which is iPad. An iPad Air 13-inch (M3) on iPadOS 27
        /// does show one, but that is one model, so the form still asks
        /// "if shown" rather than promising a figure other iPads may lack.
        public let cycleCountInSettings: Bool?
        /// Where Maximum Capacity lives on this model.
        public let settingsPath: String
    }

    /// The rating for a product name as Apple sells it ("iPhone 13",
    /// "iPhone 17 Pro Max", "iPad Air 13-inch (M3)"). Keyed on the marketing
    /// name, not the hardware identifier, because identifiers do not track
    /// generations — an iPhone 14 Pro is iPhone15,2.
    public static func rating(forModelName name: String?) -> Rating? {
        guard let name else { return nil }
        if name.hasPrefix("iPad") {
            return Rating(ratedCycles: 1000, cycleCountInSettings: nil,
                          settingsPath: "Settings › Battery › Battery Health")
        }
        guard name.hasPrefix("iPhone") else { return nil }
        let rest = name.dropFirst("iPhone".count).drop { $0 == " " }
        let generation = Int(rest.prefix { $0.isNumber })
        // iPhone Air arrived with the iPhone 17 family. Everything without a
        // number — X, XS, XR, SE — predates iPhone 15.
        let modern = rest.hasPrefix("Air") || (generation ?? 0) >= 15
        return modern
            ? Rating(ratedCycles: 1000, cycleCountInSettings: true,
                     settingsPath: "Settings › Battery › Battery Health")
            : Rating(ratedCycles: 500, cycleCountInSettings: false,
                     settingsPath: "Settings › Battery › Battery Health & Charging")
    }

    public struct Assessment: Sendable {
        /// Pass at 80% and above — within what Apple designs for. Warn below.
        public let verdict: AgentVerdict
        /// One or two words: "Very good", "Worn".
        public let condition: String
        /// What that means for the person holding the device.
        public let meaning: String
        /// "312 of 1000 rated cycles (31%)", when a cycle count is known.
        public let cycles: String?
        /// How the wear compares with Apple's design pace, when both figures
        /// are known. Short form for a table, long form for a note.
        public let paceShort: String?
        public let pace: String?
    }

    public static func assess(capacity: Double, cycles: Int?, rating: Rating?) -> Assessment {
        let (verdict, condition, meaning): (AgentVerdict, String, String) = switch capacity {
        case 95...:
            (.pass, "Like new", "The battery holds almost all of its original charge.")
        case 90..<95:
            (.pass, "Very good", "Barely worn — battery life is close to what it was new.")
        case 85..<90:
            (.pass, "Good", "Normal wear. A little less time between charges than when new, "
                + "and well within what Apple designs for.")
        case 80..<85:
            (.pass, "Fair", "Normal wear, approaching the 80% Apple designs batteries to "
                + "keep. Still healthy, but you'll notice shorter battery life than new.")
        default:
            (.warn, "Worn", "Below the 80% Apple designs batteries to keep. Expect noticeably "
                + "shorter battery life; a replacement is worth considering.")
        }

        var cyclesText: String?
        var paceShort: String?
        var pace: String?
        if let cycles, let rating {
            let used = Double(cycles) / Double(rating.ratedCycles) * 100
            cyclesText = "\(cycles) of \(rating.ratedCycles) rated cycles (\(Int(used.rounded()))%)"
            // Apple's design point is 80% at the rated count. A straight line
            // from 100% is a rough guide to where a battery on that path sits;
            // real curves are not linear, so only a clear gap is called out.
            let expected = max(100 - 20 * Double(cycles) / Double(rating.ratedCycles), 0)
            if capacity >= expected - 3 {
                paceShort = "On or ahead of Apple's design"
                pace = "At \(cycles) cycles a battery on Apple's design path would be around "
                    + "\(Int(expected.rounded()))%; this one is \(Int(capacity.rounded()))%, so it is "
                    + "ageing as designed or better."
            } else {
                paceShort = "Wearing faster than designed"
                pace = "At \(cycles) cycles a battery on Apple's design path would be around "
                    + "\(Int(expected.rounded()))%; this one is \(Int(capacity.rounded()))%. Heat and "
                    + "long stretches at full charge speed up wear, so charging settings that "
                    + "avoid sitting at 100% help."
            }
        } else if let cycles {
            cyclesText = "\(cycles) cycles"
        }
        return Assessment(verdict: verdict, condition: condition, meaning: meaning,
                          cycles: cyclesText, paceShort: paceShort, pace: pace)
    }
}
