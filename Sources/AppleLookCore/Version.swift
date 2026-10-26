import Foundation

/// Dotted version numbers like "0.2.1" or GitHub tags like "v0.2.1".
public enum Version {
    public static func parts(_ s: String) -> [Int] {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let bare = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        return bare.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// True when `candidate` is a later version than `current` ("0.10" > "0.9").
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
