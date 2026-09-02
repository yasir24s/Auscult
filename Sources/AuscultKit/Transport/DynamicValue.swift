import Foundation

/// A tolerant reader over untyped JSON / plist trees.
///
/// Auscult never decodes Apple's output into a fixed `Codable` struct. Apple
/// reserves the right to rename, nest, or drop any key between betas — and does
/// (`hardwareProperties` is already deprecated in favour of `properties`). A
/// strict decoder turns that into a total failure. Instead every read goes
/// through a *list* of candidate key paths, newest first, and yields `.missing`
/// rather than throwing when none match.
/// `raw` only ever holds the immutable value types `JSONSerialization` and
/// `PropertyListSerialization` produce — dictionaries, arrays, strings, and
/// `NSNumber` — and `DynamicValue` never mutates it. `Any` can't express that
/// to the compiler, hence `@unchecked`.
@dynamicMemberLookup
public struct DynamicValue: @unchecked Sendable {
    public let raw: Any?

    public init(_ raw: Any?) { self.raw = raw }

    public static let missing = DynamicValue(nil)

    public static func parseJSON(_ data: Data) -> DynamicValue {
        DynamicValue(try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public static func parsePlist(_ data: Data) -> DynamicValue {
        DynamicValue(try? PropertyListSerialization.propertyList(from: data, format: nil))
    }

    // MARK: Navigation

    public subscript(key: String) -> DynamicValue {
        DynamicValue((raw as? [String: Any])?[key])
    }

    public subscript(index: Int) -> DynamicValue {
        guard let arr = raw as? [Any], arr.indices.contains(index) else { return .missing }
        return DynamicValue(arr[index])
    }

    public subscript(dynamicMember member: String) -> DynamicValue { self[member] }

    /// Follow a dotted path. Numeric components index into arrays.
    /// `"properties.hardware.supportedCPUTypes.0.type"`
    public func path(_ dotted: String) -> DynamicValue {
        dotted.split(separator: ".").reduce(self) { acc, part in
            if let i = Int(part) { return acc[i] }
            return acc[String(part)]
        }
    }

    /// First path that resolves to a present value. Order = preference.
    public func firstPresent(_ paths: String...) -> DynamicValue { firstPresent(paths) }

    public func firstPresent(_ paths: [String]) -> DynamicValue {
        for p in paths {
            let v = path(p)
            if v.exists { return v }
        }
        return .missing
    }

    /// Depth-first search for the first value under any key matching `key`.
    /// The escape hatch for when a beta moves a key somewhere we didn't predict.
    public func search(forKey key: String, maxDepth: Int = 8) -> DynamicValue {
        guard maxDepth > 0 else { return .missing }
        if let dict = raw as? [String: Any] {
            if let hit = dict[key] { return DynamicValue(hit) }
            for v in dict.values {
                let r = DynamicValue(v).search(forKey: key, maxDepth: maxDepth - 1)
                if r.exists { return r }
            }
        } else if let arr = raw as? [Any] {
            for v in arr {
                let r = DynamicValue(v).search(forKey: key, maxDepth: maxDepth - 1)
                if r.exists { return r }
            }
        }
        return .missing
    }

    /// Collect every value stored under `key`, at any depth.
    public func searchAll(forKey key: String, maxDepth: Int = 10) -> [DynamicValue] {
        var found: [DynamicValue] = []
        func walk(_ v: Any?, _ depth: Int) {
            guard depth > 0 else { return }
            if let dict = v as? [String: Any] {
                for (k, sub) in dict {
                    if k == key { found.append(DynamicValue(sub)) }
                    walk(sub, depth - 1)
                }
            } else if let arr = v as? [Any] {
                for sub in arr { walk(sub, depth - 1) }
            }
        }
        walk(raw, maxDepth)
        return found
    }

    // MARK: Extraction

    public var exists: Bool { raw != nil && !(raw is NSNull) }

    public var string: String? {
        switch raw {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let b as Bool: return b ? "true" : "false"
        default: return nil
        }
    }

    public var int: Int64? {
        switch raw {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var double: Double? {
        switch raw {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var bool: Bool? {
        switch raw {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "yes", "1", "enabled": return true
            case "false", "no", "0", "disabled": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var array: [DynamicValue] {
        (raw as? [Any])?.map(DynamicValue.init) ?? []
    }

    public var dictionary: [String: DynamicValue] {
        (raw as? [String: Any])?.mapValues(DynamicValue.init) ?? [:]
    }

    public var stringList: [String] {
        if let arr = raw as? [Any] {
            return arr.compactMap { DynamicValue($0).string }
        }
        return string.map { [$0] } ?? []
    }

    /// Numeric data that Apple sometimes hands back as a hex string.
    public var intFromAnyRadix: Int64? {
        if let i = int { return i }
        guard var s = string?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if s.hasPrefix("0x") { s.removeFirst(2); return Int64(s, radix: 16) }
        return nil
    }
}
