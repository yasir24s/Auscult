import Foundation

/// Marketing names for hardware we can only identify by model code.
///
/// A proxied accessory never introduces itself — the only identification is a
/// `modelCode` buried in a forwarded crash report. Translating it is the
/// difference between "Watch6,13" and "Apple Watch SE (2nd generation), 44mm".
///
/// Deliberately partial. An unknown code returns the raw string rather than a
/// guess, because a wrong model name would quietly mislead every figure that
/// depends on it.
public enum AccessoryNames {
    static let watches: [String: String] = [
        "Watch5,9": "Apple Watch SE (1st generation), 40mm",
        "Watch5,10": "Apple Watch SE (1st generation), 44mm",
        "Watch6,1": "Apple Watch Series 6, 40mm",
        "Watch6,2": "Apple Watch Series 6, 44mm",
        "Watch6,6": "Apple Watch Series 7, 41mm",
        "Watch6,7": "Apple Watch Series 7, 45mm",
        "Watch6,10": "Apple Watch SE (2nd generation), 40mm",
        "Watch6,11": "Apple Watch SE (2nd generation), 44mm",
        "Watch6,12": "Apple Watch SE (2nd generation), 40mm, cellular",
        "Watch6,13": "Apple Watch SE (2nd generation), 44mm, cellular",
        "Watch6,14": "Apple Watch Series 8, 41mm",
        "Watch6,15": "Apple Watch Series 8, 45mm",
        "Watch6,18": "Apple Watch Ultra",
        "Watch7,1": "Apple Watch Series 10, 42mm",
        "Watch7,2": "Apple Watch Series 10, 46mm",
        "Watch7,5": "Apple Watch Ultra 2",
    ]

    public static func describe(_ modelCode: String) -> String {
        watches[modelCode] ?? modelCode
    }
}
