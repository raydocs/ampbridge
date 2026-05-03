import Foundation

enum ProviderRoutingMode: String, Equatable {
    case local
    case official

    static func parse(_ value: String?) -> ProviderRoutingMode {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "official", "native", "amp", "official-api":
            return .official
        default:
            return .local
        }
    }
}
