import Shared
import UIKit

public enum Talk360Theme {
    case light
    case dark
    case system

    var value: String {
        switch self {
        case .light: return "light"
        case .dark: return "dark"
        case .system: return "system"
        }
    }
}

/// Brand color overrides applied to the dialer's UI.
///
/// Pass colors that match your app's current theme state at the time you open the dialer —
/// the SDK does not reactively swap palettes if the device switches between light and dark
/// mode mid-session. If you use `Talk360Theme.system`, read `traitCollection.userInterfaceStyle`
/// (or your SwiftUI environment) before constructing this struct so the colors line up with
/// the theme the web dialer will render.
///
/// `UIColor` instances can come from any source: asset catalogs (`UIColor(named:)`), system
/// colors (`.systemBackground`), color literals, or `UIColor(cssHex:)` for hex specs.
public struct Talk360BrandColors {
    public let primary: UIColor?
    public let secondary: UIColor?
    public let background: UIColor?
    public let textOnPrimary: UIColor?
    public let textPrimary: UIColor?

    public init(
        primary: UIColor? = nil,
        secondary: UIColor? = nil,
        background: UIColor? = nil,
        textOnPrimary: UIColor? = nil,
        textPrimary: UIColor? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.background = background
        self.textOnPrimary = textOnPrimary
        self.textPrimary = textPrimary
    }
}

public struct Talk360BootConfig {
    public let jwt: String
    public let tenantId: String
    public let locale: String
    public let environment: Talk360Environment
    public let theme: Talk360Theme
    public let destination: String?
    public let brandColors: Talk360BrandColors?

    public init(
        jwt: String,
        tenantId: String,
        locale: String,
        environment: Talk360Environment = .staging,
        theme: Talk360Theme = .system,
        destination: String? = nil,
        brandColors: Talk360BrandColors? = nil
    ) {
        precondition(!jwt.isEmpty, "jwt must not be blank")
        precondition(!tenantId.isEmpty, "tenantId must not be blank")
        precondition(!locale.isEmpty, "locale must not be blank")
        self.jwt = jwt
        self.tenantId = tenantId
        self.locale = locale
        self.environment = environment
        self.theme = theme
        self.destination = destination
        self.brandColors = brandColors
    }
}

