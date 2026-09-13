import Foundation
import RawCore

/// The isolated raw decoder. Lives in Latent.app/Contents/XPCServices,
/// sandboxed with no entitlements beyond the sandbox itself: no files,
/// no network. The host hands it an open descriptor per decode and gets
/// back metadata, the sensor plane and the embedded preview. If a file
/// crashes LibRaw, this process dies and the host gets a connection
/// error instead of a crash of its own.
final class RawDecoderService: NSObject, RawDecoderProtocol {
    func decode(_ file: FileHandle, metadataOnly: Bool,
                reply: @escaping (Data?, Data?, Data?, String?) -> Void) {
        do {
            let raw = try RawFile(fileDescriptor: file.fileDescriptor, metadataOnly: metadataOnly)
            let snap = raw.snapshot()
            let meta = try JSONEncoder().encode(snap.metadata)
            reply(meta, snap.plane, snap.preview, nil)
        } catch {
            reply(nil, nil, nil, String(describing: error))
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: RawDecoderProtocol.self)
        connection.exportedObject = RawDecoderService()
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
