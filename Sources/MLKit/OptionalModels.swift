import Foundation
import CryptoKit

/// A model the app can fetch on request rather than ship, so the bundle
/// stays small. Downloads land in `CoreMLStore.externalModelsDirectory`
/// and are found by the same lookup as the bundled ones.
public struct OptionalModel: Sendable, Identifiable {
    public let id: String            // package name
    public let title: String
    public let sizeMB: Int
    public let url: URL
    /// SHA-256 of the zip as published; a mismatch is refused.
    public let sha256: String

    public var installedURL: URL {
        CoreMLStore.externalModelsDirectory.appendingPathComponent(id + ".mlpackage")
    }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: installedURL.path) }

    /// NAFNet SIDD width 64: ~0.3 dB better than the bundled width-32
    /// model on SIDD, at about four times the compute. Not published, and
    /// nothing in the app offers the download (DESIGN.md §4a).
    public static let nafnetWidth64 = OptionalModel(
        id: "NAFNet_SIDD_width64",
        title: "NAFNet high-quality denoiser",
        sizeMB: 214,
        url: URL(string: "https://github.com/Harmanjit/latent-raw/releases/download/models-v1/NAFNet_SIDD_width64.mlpackage.zip")!,
        sha256: "f8671a233053cc9549d138f4dcfce8f5f730c3a9310584e1ab9bcb46cb34bc5f")

    public static let all: [OptionalModel] = [nafnetWidth64]
}

public enum ModelDownloadError: Error, CustomStringConvertible {
    case badStatus(Int)
    case checksumMismatch
    case unzipFailed(String)

    public var description: String {
        switch self {
        case .badStatus(let code): "Download failed (HTTP \(code)). The model may not be published yet."
        case .checksumMismatch: "Downloaded file didn't match its checksum; not installed."
        case .unzipFailed(let msg): "Could not unpack the model: \(msg)"
        }
    }
}

/// Downloads, verifies and installs an optional model.
public enum ModelDownloader {
    /// Fetches the zip to a temporary file, reporting bytes received and
    /// expected, checks the SHA-256, unpacks with `ditto` into the
    /// external models directory (replacing any previous copy), and
    /// removes the zip. Cancellation is honoured mid-download.
    public static func install(_ model: OptionalModel,
                               progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: model.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelDownloadError.badStatus(http.statusCode)
        }
        let expected = response.expectedContentLength
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(model.id + "-" + UUID().uuidString + ".zip")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }

        var hasher = SHA256()
        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                hasher.update(data: buffer); try handle.write(contentsOf: buffer)
                received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                progress?(received, expected)
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty {
            hasher.update(data: buffer); try handle.write(contentsOf: buffer); received += Int64(buffer.count)
        }
        try handle.close()
        progress?(received, expected)

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard model.sha256 == "SHA256_PLACEHOLDER" || digest == model.sha256 else {
            throw ModelDownloadError.checksumMismatch
        }
        try unzip(temp, into: CoreMLStore.externalModelsDirectory, replacing: model.installedURL)
    }

    /// Entry names an archive may contain: relative, no parent references,
    /// no absolute paths. Checked before anything is written, so a zip
    /// that tries to climb out of the models folder is refused whole.
    static func entriesAreSafe(_ entries: [String]) -> Bool {
        for e in entries {
            let name = e.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            if name.hasPrefix("/") || name.hasPrefix("\\") || name.contains("../") || name.hasPrefix("..")
                || name.contains("/../") || name.hasSuffix("/..") || name.contains("\u{0}") {
                return false
            }
        }
        return true
    }

    static func listEntries(_ zip: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", zip.path]
        let out = Pipe(); process.standardOutput = out; process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ModelDownloadError.unzipFailed("could not list the archive") }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    static func unzip(_ zip: URL, into directory: URL, replacing target: URL) throws {
        let fm = FileManager.default
        let entries = try listEntries(zip)
        guard entriesAreSafe(entries) else {
            throw ModelDownloadError.unzipFailed("archive contains unsafe paths; refused")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        let err = Pipe(); process.standardError = err
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ModelDownloadError.unzipFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard fm.fileExists(atPath: target.path) else {
            throw ModelDownloadError.unzipFailed("archive did not contain \(target.lastPathComponent)")
        }
    }

    public static func remove(_ model: OptionalModel) throws {
        if model.isInstalled { try FileManager.default.removeItem(at: model.installedURL) }
    }
}
