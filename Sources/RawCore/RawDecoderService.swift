import Foundation
import IOSurface

/// The decoder service's exported object (the service's `main.swift`
/// exports one per connection). It lives here rather than in the service
/// target so tests can export it on an anonymous listener.
///
/// NSXPC delivers a connection's messages one at a time, so work done
/// inside the handler would serialise every decode the app has in flight:
/// an editor open would wait behind four thumbnail renders. Each request
/// is instead run on a concurrent queue and replied to from there (a
/// reply may be sent after the handler returns), as decodes run when the
/// app decodes in its own process.
///
/// A file that sends LibRaw into an endless loop can't be stopped from
/// outside its thread, and the app stops waiting for it after
/// `RawDecoderXPC.requestTimeout`. So every request runs under a watchdog:
/// one that is still running after `RawDecoderXPC.serviceWatchdog` ends
/// the whole process, and the stuck decode with it, rather than leave it
/// spinning a core and holding its buffers until the app quits. Requests
/// in flight at that moment from other callers fail as they would after a
/// crash, and the app's next request starts a fresh service. The watchdog
/// is per request rather than tied to the app's connections, which all
/// reach this one process and come and go on their own schedule.
public final class RawDecoderService: NSObject, RawDecoderProtocol {
    typealias Reply = (Data?, IOSurface?, Data?, String?) -> Void
    /// Decodes the file behind the descriptor and replies, within its own
    /// scope so the decoded file (and its surface) outlives the reply.
    typealias DecodeWork = @Sendable (_ fd: Int32, _ metadataOnly: Bool, _ reply: Reply) -> Void

    private let decodeWork: DecodeWork
    private let watchdog: TimeInterval
    private let onStuck: @Sendable () -> Void
    private static let queue = DispatchQueue(label: "com.latent.rawdecoder.work", qos: .userInitiated,
                                             attributes: .concurrent)

    public override convenience init() {
        self.init(decodeWork: Self.decodeFile)
    }

    /// `decodeWork` stands in for LibRaw in tests, and `onStuck` for the
    /// exit, which would end the test runner.
    init(decodeWork: @escaping DecodeWork, watchdog: TimeInterval = RawDecoderXPC.serviceWatchdog,
         onStuck: @escaping @Sendable () -> Void = RawDecoderService.exitStuck) {
        self.decodeWork = decodeWork
        self.watchdog = watchdog
        self.onStuck = onStuck
    }

    /// Ends the service. `_exit` rather than `exit`: the stuck thread may
    /// hold locks that exit-time cleanup would wait on.
    static let exitStuck: @Sendable () -> Void = {
        RawDecoderXPC.logger.error("raw decoder request ran past \(Int(RawDecoderXPC.serviceWatchdog)) s; ending the service")
        _exit(1)
    }

    /// Runs one request on the work queue with the watchdog armed from
    /// when it starts until it returns.
    private func run(_ body: @escaping @Sendable () -> Void) {
        let watchdog = watchdog
        let onStuck = onStuck
        Self.queue.async {
            let alarm = DispatchWorkItem(block: onStuck)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + watchdog, execute: alarm)
            body()
            alarm.cancel()
        }
    }

    public func decode(_ file: FileHandle, metadataOnly: Bool,
                       reply: @escaping (Data?, IOSurface?, Data?, String?) -> Void) {
        let work = decodeWork
        // The handle keeps the descriptor open until the work is done.
        nonisolated(unsafe) let file = file
        nonisolated(unsafe) let reply = reply
        run {
            work(file.fileDescriptor, metadataOnly, reply)
        }
    }

    public func readMetadata(_ file: FileHandle, reply: @escaping (Data?, Data?, String?) -> Void) {
        nonisolated(unsafe) let file = file
        nonisolated(unsafe) let reply = reply
        run {
            do {
                let metadata = try SourceMetadata(fileDescriptor: file.fileDescriptor)
                reply(metadata.properties, metadata.xmpTags, nil)
            } catch {
                reply(nil, nil, String(describing: error))
            }
        }
    }

    static func decodeFile(fd: Int32, metadataOnly: Bool, reply: Reply) {
        do {
            let raw = try RawFile(fileDescriptor: fd, metadataOnly: metadataOnly)
            let meta = try JSONEncoder().encode(raw.snapshotMetadata)
            // A preview past the cap stays here rather than being copied
            // into the app, which would refuse it anyway (see
            // `RawDecoderXPC.maxPreviewBytes`).
            let preview = raw.embeddedJPEGPreview().flatMap { $0.count <= RawDecoderXPC.maxPreviewBytes ? $0 : nil }
            // One surface either way: the metadata's source kind tells the
            // app whether it holds sensor counts or linear RGB.
            reply(meta, raw.sensorPlane?.surface ?? raw.linearPlane?.surface, preview, nil)
        } catch {
            reply(nil, nil, nil, String(describing: error))
        }
    }
}
