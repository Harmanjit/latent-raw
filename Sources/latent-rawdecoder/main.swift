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
///
/// A request stuck in LibRaw is ended by the service's own watchdog
/// (see `RawDecoderService`), not by connections closing.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = RawDecoderXPC.makeInterface()
        connection.exportedObject = RawDecoderService()
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
