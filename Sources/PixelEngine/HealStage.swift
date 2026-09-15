import Foundation
import Metal
import simd

/// Mirror of `HealGridGPU` in Heal.metal: where one patch lands on the
/// texture being rendered, in texture pixels.
struct HealGridGPU {
    var target: SIMD2<Float>
    var offset: SIMD2<Float>
    var radius: Float
    var feather: Float
    var cell: Float
    var sigma: Float            // in cells
    var gridOrigin: SIMD2<Float>
    var gridSize: SIMD2<Int32>
    var boxOrigin: SIMD2<Int32>
    var boxSize: SIMD2<Int32>
}

/// The sizes behind a heal's ratio field, for a patch of `radius`
/// pixels (texture pixels when rendering, sensor pixels when planning a
/// region at full resolution).
struct HealFieldLayout {
    let radius: Float
    /// Half the radius: wide enough to reach past the feathered edge for
    /// surroundings on every side, narrow enough to follow a curving
    /// gradient (minivu measured a full-radius sigma worse on a sky).
    let sigma: Float
    /// Pixels per grid cell. The field is smooth at the scale of sigma, so
    /// cells of up to a quarter sigma lose nothing visible and keep the
    /// blur to a few dozen cells a side for any radius.
    let cell: Int

    init(radius: Float) {
        self.radius = max(radius, 0)
        sigma = max(0.5 * self.radius, 0.5)
        cell = sigma <= 4 ? 1 : Int((sigma / 4).rounded(.up))
    }

    var sigmaCells: Float { sigma / Float(cell) }

    /// Cells of grid beyond the patch's bounding box: the blur's reach,
    /// one for the bilinear lookup and one spare.
    var paddingCells: Int { Int((3 * sigmaCells).rounded(.up)) + 2 }

    /// How far from the target (and source) centre a heal reads.
    var reach: Float { radius + 3 + Float((paddingCells + 2) * cell) }
}

/// Encodes spot removal (Heal.metal) onto a command buffer. Separate from
/// RenderPipeline so tests can run it on a synthetic texture.
enum HealStage {
    /// Writes `input` with `patches` applied, in order, into `output` (same
    /// size and format). `sensorSize` is the whole sensor; `tileOrigin` and
    /// `binSpan` place the texture on it, as for the other stages.
    static func encode(patches: [HealPatch], input: MTLTexture, output: MTLTexture,
                       sensorSize: SIMD2<Float>, tileOrigin: SIMD2<Float>, binSpan: Float,
                       gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws {
        guard input.width == output.width, input.height == output.height,
              input.pixelFormat == output.pixelFormat,
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        // Patches read and write the working copy; the input may be the
        // session's cached demosaic, which must stay as it is.
        blit.copy(from: input, to: output)
        blit.endEncoding()

        let placed = patches.prefix(HealPatch.maximumCount).compactMap {
            place($0, width: input.width, height: input.height,
                  sensorSize: sensorSize, tileOrigin: tileOrigin, binSpan: binSpan)
        }
        guard !placed.isEmpty else { return }

        // Shared by every patch in this render, sized for the largest.
        // The grids are Float32 so a smooth field doesn't band.
        let gridW = Int(placed.map { $0.grid.gridSize.x }.max()!)
        let gridH = Int(placed.map { $0.grid.gridSize.y }.max()!)
        let boxW = Int(placed.map { $0.grid.boxSize.x }.max()!)
        let boxH = Int(placed.map { $0.grid.boxSize.y }.max()!)
        guard let fieldT = gpu.makePrivateTexture(width: gridW, height: gridH, pixelFormat: .rgba32Float),
              let fieldS = gpu.makePrivateTexture(width: gridW, height: gridH, pixelFormat: .rgba32Float),
              let blurT = gpu.makePrivateTexture(width: gridW, height: gridH, pixelFormat: .rgba32Float),
              let blurS = gpu.makePrivateTexture(width: gridW, height: gridH, pixelFormat: .rgba32Float),
              let scratch = gpu.makePrivateTexture(width: boxW, height: boxH, pixelFormat: output.pixelFormat),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.gpuBufferAllocationFailed
        }
        var sensorSize = sensorSize, tileOrigin = tileOrigin, span = binSpan
        let gridBytes = MemoryLayout<HealGridGPU>.stride
        for var (patch, grid) in placed {
            let gridCells = (Int(grid.gridSize.x), Int(grid.gridSize.y))
            if patch.params.z < 0.5 {
                encoder.setComputePipelineState(gpu.healGatherPSO)
                encoder.setTexture(output, index: 0)
                encoder.setTexture(fieldT, index: 1)
                encoder.setTexture(fieldS, index: 2)
                encoder.setBytes(&grid, length: gridBytes, index: 0)
                dispatch(encoder, gpu.healGatherPSO, gridCells)

                for (vertical, from, to) in [(Int32(0), (fieldT, fieldS), (blurT, blurS)),
                                             (Int32(1), (blurT, blurS), (fieldT, fieldS))] {
                    var vertical = vertical
                    encoder.setComputePipelineState(gpu.healBlurPSO)
                    encoder.setTexture(from.0, index: 0)
                    encoder.setTexture(from.1, index: 1)
                    encoder.setTexture(to.0, index: 2)
                    encoder.setTexture(to.1, index: 3)
                    encoder.setBytes(&grid, length: gridBytes, index: 0)
                    encoder.setBytes(&vertical, length: 4, index: 1)
                    dispatch(encoder, gpu.healBlurPSO, gridCells)
                }
            }

            let boxPixels = (Int(grid.boxSize.x), Int(grid.boxSize.y))
            encoder.setComputePipelineState(gpu.healApplyPSO)
            encoder.setTexture(output, index: 0)
            encoder.setTexture(fieldT, index: 1)
            encoder.setTexture(fieldS, index: 2)
            encoder.setTexture(scratch, index: 3)
            encoder.setBytes(&patch, length: MemoryLayout<HealPatchGPU>.stride, index: 0)
            encoder.setBytes(&grid, length: gridBytes, index: 1)
            encoder.setBytes(&sensorSize, length: 8, index: 2)
            encoder.setBytes(&tileOrigin, length: 8, index: 3)
            encoder.setBytes(&span, length: 4, index: 4)
            dispatch(encoder, gpu.healApplyPSO, boxPixels)

            encoder.setComputePipelineState(gpu.healPastePSO)
            encoder.setTexture(scratch, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBytes(&grid, length: gridBytes, index: 0)
            dispatch(encoder, gpu.healPastePSO, boxPixels)
        }
        encoder.endEncoding()
    }

    /// The patch's placement on a `width` x `height` texture, or nil when
    /// its target misses the texture entirely.
    static func place(_ p: HealPatch, width: Int, height: Int, sensorSize: SIMD2<Float>,
                      tileOrigin: SIMD2<Float>, binSpan: Float) -> (patch: HealPatchGPU, grid: HealGridGPU)? {
        let radius = p.radius * min(sensorSize.x, sensorSize.y) / binSpan
        let target = (p.target * sensorSize - tileOrigin) / binSpan
        let source = (p.source * sensorSize - tileOrigin) / binSpan
        let lo = (target - radius - 1).rounded(.down)
        let hi = (target + radius + 1).rounded(.up)
        let x0 = max(0, Int(lo.x)), y0 = max(0, Int(lo.y))
        let x1 = min(width, Int(hi.x)), y1 = min(height, Int(hi.y))
        guard x1 > x0, y1 > y0, radius > 0 else { return nil }

        let layout = HealFieldLayout(radius: radius)
        let cell = Float(layout.cell), padding = Float(layout.paddingCells)
        var gridSize = SIMD2<Int32>(1, 1)
        if p.mode == .heal {
            let cells = Int32(((hi.x - lo.x) / cell).rounded(.up)) + 2 * Int32(layout.paddingCells) + 1
            gridSize = SIMD2(cells, cells)
        }
        let grid = HealGridGPU(target: target, offset: source - target, radius: radius, feather: p.feather,
                               cell: cell, sigma: layout.sigmaCells,
                               gridOrigin: lo - padding * cell, gridSize: gridSize,
                               boxOrigin: SIMD2(Int32(x0), Int32(y0)),
                               boxSize: SIMD2(Int32(x1 - x0), Int32(y1 - y0)))
        return (HealPatchGPU(p), grid)
    }

    private static func dispatch(_ encoder: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState,
                                 _ size: (Int, Int)) {
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (size.0 + tw - 1) / tw, height: (size.1 + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }
}
