import Foundation
import os

/// Centralizovaný `os.Logger` namespace.
///
/// `os.Logger` je Apple-native, hraje s Console.app a Instruments time-correlation,
/// respektuje `OSLogStore` pro historický replay. Migrace ze stderr callsites
/// je opportunistic — nový kód používá `SPZLog.<category>.<level>(...)`.
///
/// **Subsystem** odráží bundle ID. **Categories** rozdělují logické moduly.
enum SPZLog {
    private static let subsystem = "app.macplategate"

    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let tracker = Logger(subsystem: subsystem, category: "tracker")
    static let ocr = Logger(subsystem: subsystem, category: "ocr")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let camera = Logger(subsystem: subsystem, category: "camera")
    static let audit = Logger(subsystem: subsystem, category: "audit")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let webserver = Logger(subsystem: subsystem, category: "webserver")
    static let health = Logger(subsystem: subsystem, category: "health")
}
