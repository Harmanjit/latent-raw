import Foundation
import IOSurface
import RawCore

/// The isolated raw decoder. Lives in Latent.app/Contents/XPCServices,
/// sandboxed with no entitlements beyond the sandbox itself: no files,
/// no network. The host hands it an open descriptor per decode and gets
/// back metadata, the sensor plane (as a shared IOSurface, written once
/// here and read in place by the app's GPU) and the embedded preview. If a file
/// crashes LibRaw, this process dies and the host gets a connection
/// error instead of a crash of its own.
final class RawDecoderService: NSObject, RawDecoderProtocol {
    func decode(_ file: FileHandle, metadataOnly: Bool,
                reply: @escaping (Data?, IOSurface?, Data?, String?) -> Void) {
        do {
            let raw = try RawFile(fileDescriptor: file.fileDescriptor, metadataOnly: metadataOnly)
            let meta = try JSONEncoder().encode(raw.snapshotMetadata)
            reply(meta, raw.sensorPlane?.surface, raw.embeddedJPEGPreview(), nil)
        } catch {
            reply(nil, nil, nil, String(describing: error))
        }
    }

    func readMetadata(_ file: FileHandle, reply: @escaping (Data?, Data?, String?) -> Void) {
        do {
            let metadata = try SourceMetadata(fileDescriptor: file.fileDescriptor)
            reply(metadata.properties, metadata.xmpTags, nil)
        } catch {
            reply(nil, nil, String(describing: error))
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
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
