// What an analysis or merge cost: time per stage and GPU memory. Not part
// of the contract the app builds against (HDRMergeAPI.swift); the CLI and
// the performance tests read it.

import Foundation
import Metal

/// How long each stage of an analysis or merge took, and the most GPU
/// memory the process had allocated while it ran.
public struct HDRMergeReport: Sendable, Equatable {
    public struct Stage: Sendable, Equatable {
        public let name: String
        public let seconds: Double
    }

    public private(set) var stages: [Stage] = []
    /// The largest `MTLDevice.currentAllocatedSize` seen at the points
    /// where the merge holds the most (after each frame's GPU work, before
    /// its textures are reused or released). It counts every allocation in
    /// the process, so it includes whatever else the process holds.
    public private(set) var peakGPUBytes = 0

    public init() {}

    public var totalSeconds: Double { stages.reduce(0) { $0 + $1.seconds } }

    /// Runs `body`, recording its duration under `name`.
    mutating func time<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let clock = ContinuousClock(), start = clock.now
        defer { record(name, since: start, clock: clock) }
        return try body()
    }

    /// The same, for work that awaits.
    mutating func time<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock(), start = clock.now
        defer { record(name, since: start, clock: clock) }
        return try await body()
    }

    mutating func sampleMemory(_ device: MTLDevice) {
        peakGPUBytes = max(peakGPUBytes, device.currentAllocatedSize)
    }

    mutating func append(_ other: HDRMergeReport) {
        stages += other.stages
        peakGPUBytes = max(peakGPUBytes, other.peakGPUBytes)
    }

    private mutating func record(_ name: String, since start: ContinuousClock.Instant, clock: ContinuousClock) {
        let elapsed = clock.now - start
        stages.append(Stage(name: name, seconds: Double(elapsed.components.seconds)
                                + Double(elapsed.components.attoseconds) * 1e-18))
    }
}
