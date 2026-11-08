//
//  CivilDate.swift
//  Lume
//

nonisolated enum CivilDate {
    /// Days from 1970-01-01 to a proleptic-Gregorian date (Howard Hinnant's
    /// `days_from_civil`). Avoids `Calendar`, which is itself locale-aware and
    /// far slower than this arithmetic.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
