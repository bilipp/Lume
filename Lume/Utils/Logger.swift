import OSLog

nonisolated extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier!
    static let database = Logger(subsystem: subsystem, category: "Database")
    static let network = Logger(subsystem: subsystem, category: "Network")
    static let player = Logger(subsystem: subsystem, category: "Player")
    static let sync = Logger(subsystem: subsystem, category: "CloudSync")
    static let downloads = Logger(subsystem: subsystem, category: "Downloads")
    static let indexing = Logger(subsystem: subsystem, category: "Indexing")
    static let premium = Logger(subsystem: subsystem, category: "Premium")
    static let memory = Logger(subsystem: subsystem, category: "Memory")
    /// Shares its category with `Perf`'s signposts, so one filter shows both the
    /// phase boundaries and the messages explaining them.
    static let performance = Logger(subsystem: subsystem, category: "Performance")
}
