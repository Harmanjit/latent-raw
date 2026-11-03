import Foundation
import IOSurface
import RawCore

/// The isolated raw decoder. Lives in Latent.app/Contents/XPCServices,
/// sandboxed with no entitlements beyond the sandbox itself: no files,
/// no network. The host hands it an open descriptor per decode and gets
/// back metadata, the sensor plane or a linear source's pixels (as a
/// shared IOSurface, written once here and read in place by the app's
/// GPU) and the embedded preview. If a file
/// crashes LibRaw, this process dies and the host gets a connection
/// error instead of a crash of its own. The exported object,
/// `RawDecoderService`, is in RawCore.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var openConnections = 0

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = RawDecoderXPC.makeInterface()
        connection.exportedObject = RawDecoderService()
        // The app drops its connection when a decode outlives its deadline
        // (`RawDecoderClient`). Leaving once no connection is left ends the
        // decode stuck in LibRaw, which nothing else could stop.
        connection.invalidationHandler = { [unowned self] in self.connectionClosed() }
        lock.lock(); openConnections += 1; lock.unlock()
        connection.resume()
        return true
    }

    private func connectionClosed() {
        lock.lock(); openConnections -= 1; let last = openConnections == 0; lock.unlock()
        if last { exit(0) }
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
