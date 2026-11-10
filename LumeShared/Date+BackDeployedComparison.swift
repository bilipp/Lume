//
//  Date+BackDeployedComparison.swift
//  LumeShared
//
//  The OS 27.2 SDKs declare Foundation's `Date <=` and `>=` as
//  `@backDeployed(before: … 27.2)`. Code built with them calls the system's
//  copy on anything that reports 27.2 or later and the inlined fallback below
//  that. Early 27.2 betas report 27.2 but don't export the symbol, so the weak
//  import binds to NULL and the first comparison jumps to address 0
//  (EXC_BAD_ACCESS at 0x0, "Failed to fault in a page with execute
//  permissions"). The Home sports rail compares dates on its first render, so
//  Lume crashed at every launch as soon as a playlist existed.
//
//  These two shadow Foundation's in every target that compiles LumeShared (the
//  app, the widgets and Top Shelf): a module's own declaration wins over an
//  imported one with the same signature, so no call site links the weak
//  symbol. `<`, `>` and `==` were never back-deployed and
//  stay Foundation's. Delete this file once the deployment target is 27.2.
//
//  Check after a build: `nm -m` on Lume.app/Lume and each appex, piped to
//  `grep -E 'DateV2(ge|le)oiy'`, must print nothing.
//

import Foundation

nonisolated extension Date {
    static func <= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate <= rhs.timeIntervalSinceReferenceDate
    }

    static func >= (lhs: Date, rhs: Date) -> Bool {
        lhs.timeIntervalSinceReferenceDate >= rhs.timeIntervalSinceReferenceDate
    }
}
