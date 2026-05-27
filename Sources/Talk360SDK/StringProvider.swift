import Foundation

struct StringProvider {
    func string(_ identifier: StringIdentifier) -> String {
        Bundle.module.localizedString(forKey: identifier.rawValue, value: identifier.rawValue, table: nil)
    }
}
