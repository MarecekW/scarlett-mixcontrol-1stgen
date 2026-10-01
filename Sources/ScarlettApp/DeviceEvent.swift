import Foundation
import SwiftUI

/// One entry in the Device-tab event log. Lightweight, value-typed,
/// Identifiable so SwiftUI ForEach can render them.
public struct DeviceEvent: Identifiable, Hashable {
    public let id = UUID()
    public let timestamp: Date
    public let severity: Severity
    public let category: String
    public let message: String

    public enum Severity: String, Hashable {
        case info, warning, error

        var systemImage: String {
            switch self {
            case .info:    return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error:   return "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .info:    return Theme.textSecondary
            case .warning: return .orange
            case .error:   return Theme.failure
            }
        }
    }
}
