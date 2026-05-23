import Foundation

/// A level (tier) reference passed to ``KYCWidget/onLevelChange`` and
/// ``KYCWidget/onLevelApproved``.
public struct KYCWidgetLevel: Sendable, Equatable {
    public let slug: String
    public let index: Int
    public init(slug: String, index: Int) {
        self.slug = slug
        self.index = index
    }
}
