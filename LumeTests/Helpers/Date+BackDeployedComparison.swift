import Foundation

/// `@testable import Lume` brings in the app's `Date <=`/`>=`
/// (LumeShared/Date+BackDeployedComparison.swift) next to Foundation's, which
/// makes every `Date` comparison here ambiguous. A module's own declaration
/// wins over both, so this module carries the same two. Delete with the app's.
nonisolated extension Date {
    static func <= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate <= rhs.timeIntervalSinceReferenceDate
    }

    static func >= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate >= rhs.timeIntervalSinceReferenceDate
    }
}
