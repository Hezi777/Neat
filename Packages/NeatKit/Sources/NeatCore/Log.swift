import os

/// One subsystem, a category per module. No logging framework.
public enum Log {
    public static let subsystem = "com.hen.neat"

    public static let core = Logger(subsystem: subsystem, category: "core")
    public static let adapters = Logger(subsystem: subsystem, category: "adapters")
    public static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
