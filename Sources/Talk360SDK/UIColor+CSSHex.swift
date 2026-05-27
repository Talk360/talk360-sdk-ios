import UIKit

public extension UIColor {
    // Parses CSS hex colors: #RRGGBB or #RRGGBBAA (alpha last, as CSS specifies).
    convenience init?(cssHex: String) {
        var hex = cssHex.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        let scanner = Scanner(string: hex)
        var value: UInt64 = 0
        // Scanner.scanHexInt64 returns true if it consumed any hex chars; we require the entire
        // input to be hex, otherwise inputs like "#FF80GG" would silently produce a partial color.
        guard scanner.scanHexInt64(&value), scanner.isAtEnd else { return nil }
        let r, g, b, a: CGFloat
        switch hex.count {
        case 6:
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1.0
        case 8:
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

extension UIColor {
    // Encodes the receiver as a CSS hex string. Returns #RRGGBB when fully opaque,
    // #RRGGBBAA otherwise. Dynamic colors (e.g. UIColor.systemBackground) are explicitly
    // resolved against the current trait collection at call time.
    var cssHexString: String {
        let resolved = resolvedColor(with: .current)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        // getRed returns false for non-RGB color spaces (e.g. UIColor.black is grayscale).
        if !resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            resolved.getWhite(&white, alpha: &a)
            r = white; g = white; b = white
        }
        let red = Int(round(r * 255))
        let green = Int(round(g * 255))
        let blue = Int(round(b * 255))
        if a >= 1.0 {
            return String(format: "#%02X%02X%02X", red, green, blue)
        }
        let alpha = Int(round(a * 255))
        return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }
}
