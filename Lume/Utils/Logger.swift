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
}
