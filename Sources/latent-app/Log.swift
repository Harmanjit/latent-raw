import Foundation
import os

/// One logger per area, so `log stream --predicate 'subsystem == "com.latent.app"'`
/// shows what the app did when something went wrong. Errors that reach
/// the status bar are also logged here, with the underlying error text
/// the status bar truncates.
enum Log {
    static let app = Logger(subsystem: "com.latent.app", category: "app")
    static let catalog = Logger(subsystem: "com.latent.app", category: "catalog")
    static let editor = Logger(subsystem: "com.latent.app", category: "editor")
    static let export = Logger(subsystem: "com.latent.app", category: "export")
}
