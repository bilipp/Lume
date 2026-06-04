import OSLog

extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier!
    static let database = Logger(subsystem: subsystem, category: "Database")
    static let network = Logger(subsystem: subsystem, category: "Network")
    static let player = Logger(subsystem: subsystem, category: "Player")
}
