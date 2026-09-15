#if DEBUG
import Foundation
import CoreGraphics

/// The switches of the app's debug snapshot harness (SnapshotHarness.swift
/// in the app target, whose doc comment lists them), parsed from the
/// environment. Lives here rather than in the app target, like
/// LaunchArguments, because the app has no test target and this is easy to
/// get wrong.
///
/// Debug builds only, like the harness: a release build neither reads these
/// variables nor carries this code.
public struct SnapshotPlan: Equatable, Sendable {
    /// A state to put the window in and picture. Steps run in order, each
    /// from wherever the previous one left the window.
    public enum Step: String, CaseIterable, Sendable {
        /// The grid.
        case library
        /// Moves the selection to the next image, in whatever mode is showing.
        case next
        case loupe
        /// Develop, with its default panels open.
        case develop
        /// Develop with the crop tool armed and its panel open.
        case crop
        /// Develop with the spot removal tool armed and its panel open.
        case heal
        /// Compare, on the selection and the image after it.
        case compare
        /// The export sheet over the window.
        case export
        /// The Settings window instead of the main one.
        case settings
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case unknownSteps([String])
        case malformed(variable: String, value: String)

        public var description: String {
            switch self {
            case .unknownSteps(let names):
                "unknown steps \(names.joined(separator: ", ")); known: "
                    + Step.allCases.map(\.rawValue).joined(separator: ", ")
            case .malformed(let variable, let value):
                "\(variable)=\(value) is not a valid value"
            }
        }
    }

    /// Where the PNGs go; created if missing.
    public var directory: URL
    /// The folder to open as a catalog. Nil pictures the window as launched.
    public var folder: URL?
    public var steps: [Step] = Self.defaultSteps
    /// Window content size in points. Always set, so a picture doesn't
    /// depend on the size the window was last left at, which it reopens
    /// at otherwise.
    public var windowSize = Self.defaultWindowSize
    /// Seconds to wait once a step's work is done (image rendered,
    /// thumbnails made) before picturing, for animations and late layout.
    public var settle: Double = 1
    /// Seconds after which the whole run gives up and exits.
    public var timeout: Double = 120
    /// "light" or "dark"; nil keeps the app's own setting.
    public var appearance: String?

    /// The app's own default window size (LatentApp's `defaultSize`).
    public static let defaultWindowSize = CGSize(width: 1400, height: 900)
    public static let defaultSteps: [Step] = [.library, .loupe, .develop, .crop, .heal, .compare, .export, .settings]

    /// Nil unless LATENT_SNAPSHOT_DIR is set. Throws for a value that is
    /// set but can't be used, so a typo fails the run instead of quietly
    /// picturing something else.
    public init?(environment: [String: String]) throws {
        guard let directory = environment["LATENT_SNAPSHOT_DIR"], !directory.isEmpty else { return nil }
        self.directory = Self.fileURL(directory, isDirectory: true)
        if let folder = environment["LATENT_SNAPSHOT_FOLDER"], !folder.isEmpty {
            self.folder = Self.fileURL(folder, isDirectory: true)
        }
        if let text = environment["LATENT_SNAPSHOT_STEPS"], !text.isEmpty {
            steps = try Self.parseSteps(text)
        }
        if let text = environment["LATENT_SNAPSHOT_SIZE"], !text.isEmpty {
            guard let size = Self.parseSize(text) else {
                throw Problem.malformed(variable: "LATENT_SNAPSHOT_SIZE", value: text)
            }
            windowSize = size
        }
        settle = try Self.seconds(environment, "LATENT_SNAPSHOT_SETTLE") ?? settle
        timeout = try Self.seconds(environment, "LATENT_SNAPSHOT_TIMEOUT") ?? timeout
        if let text = environment["LATENT_SNAPSHOT_APPEARANCE"], !text.isEmpty {
            guard ["light", "dark"].contains(text.lowercased()) else {
                throw Problem.malformed(variable: "LATENT_SNAPSHOT_APPEARANCE", value: text)
            }
            appearance = text.lowercased()
        }
    }

    /// "library; loupe,develop" to its steps. Either separator, any case.
    public static func parseSteps(_ text: String) throws -> [Step] {
        let names = text.split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let unknown = names.filter { Step(rawValue: $0) == nil }
        guard unknown.isEmpty else { throw Problem.unknownSteps(unknown) }
        return names.compactMap(Step.init(rawValue:))
    }

    /// "1400x900" (either case of x) to a size; nil if malformed.
    public static func parseSize(_ text: String) -> CGSize? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let height = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The PNG for the step at `index` in `steps`: numbered from 01 so a
    /// folder listing reads in run order, and named so a repeated step
    /// ("next") doesn't overwrite an earlier picture.
    public func output(forStepAt index: Int) -> URL {
        let number = String(format: "%02d", index + 1)
        return directory.appendingPathComponent("\(number)-\(steps[index].rawValue).png")
    }

    private static func seconds(_ environment: [String: String], _ variable: String) throws -> Double? {
        guard let text = environment[variable], !text.isEmpty else { return nil }
        guard let value = Double(text), value >= 0, value.isFinite else {
            throw Problem.malformed(variable: variable, value: text)
        }
        return value
    }

    private static func fileURL(_ path: String, isDirectory: Bool) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: isDirectory)
            .standardizedFileURL
    }
}
#endif
