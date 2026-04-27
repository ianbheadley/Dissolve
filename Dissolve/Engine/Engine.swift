import Foundation
import Metal
import MetalKit
import AppKit
import simd

struct GPUParticle {
    var pos: SIMD2<Float> = .zero
    var prev: SIMD2<Float> = .zero
    var color: SIMD4<Float> = .zero
    var bornAt: Float = 0
    var seed: Float = 0
    var state: UInt32 = 0   // 0 dead, 1 anchored, 2 dynamic, 3 sleeping
    var neighbors: UInt32 = 0
}

struct GPUUniforms {
    var now: Float = 0
    var dt: Float = 0
    var viewport: SIMD2<Float> = .zero
    var count: UInt32 = 0
    var gridW: UInt32 = 0
    var gridH: UInt32 = 0
    var h: Float = 0
    var r: Float = 0
    var gravity: Float = 0
    var friction: Float = 0
    var cursor: SIMD2<Float> = SIMD2<Float>(-1e6, -1e6)
    var cursorVel: SIMD2<Float> = .zero
    var tntPos: SIMD2<Float> = .zero
    var tntT: Float = 0
}

final class Engine {
    static let maxParticles = 350_000

    let device: MTLDevice
    let queue: MTLCommandQueue

    private let psoClear: MTLComputePipelineState
    private let psoBuild: MTLComputePipelineState
    private let psoIntegrate: MTLComputePipelineState
    private let psoSolve: MTLComputePipelineState
    private let psoSleep: MTLComputePipelineState
    private let psoRender: MTLRenderPipelineState

    let particleBuffer: MTLBuffer
    private var headsBuffer: MTLBuffer?
    private var nextsBuffer: MTLBuffer

    // The single tuned aesthetic. No sliders.
    let radius: Float = 1.15
    let gravity: Float = 460
    let friction: Float = 0.55
    let substeps: Int = 4

    private var u = GPUUniforms()
    private var writeIndex: Int = 0
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()

    var cursor: CGPoint = CGPoint(x: -1e6, y: -1e6)
    private var lastCursor: CGPoint = CGPoint(x: -1e6, y: -1e6)

    private var glyphRanges: [Range<Int>] = []

    private struct ArmedTNT {
        var pos: SIMD2<Float>
        var endTime: CFTimeInterval
    }
    private var armedTNTs: [ArmedTNT] = []
    private let tntFuse: CFTimeInterval = 3.0
    private let tntRadius: Float = 240
    private let tntForce: Float = 38

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue(),
              let lib = dev.makeDefaultLibrary() else { return nil }
        self.device = dev
        self.queue = q

        guard
            let fClear = lib.makeFunction(name: "clearGrid"),
            let fBuild = lib.makeFunction(name: "buildGrid"),
            let fInt = lib.makeFunction(name: "integrate"),
            let fSolve = lib.makeFunction(name: "solve"),
            let fSleep = lib.makeFunction(name: "sleepCheck"),
            let fVS = lib.makeFunction(name: "vsParticle"),
            let fFS = lib.makeFunction(name: "fsParticle")
        else { return nil }

        do {
            psoClear = try dev.makeComputePipelineState(function: fClear)
            psoBuild = try dev.makeComputePipelineState(function: fBuild)
            psoIntegrate = try dev.makeComputePipelineState(function: fInt)
            psoSolve = try dev.makeComputePipelineState(function: fSolve)
            psoSleep = try dev.makeComputePipelineState(function: fSleep)
        } catch { return nil }

        let rd = MTLRenderPipelineDescriptor()
        rd.vertexFunction = fVS
        rd.fragmentFunction = fFS
        rd.colorAttachments[0].pixelFormat = .bgra8Unorm
        rd.colorAttachments[0].isBlendingEnabled = true
        rd.colorAttachments[0].rgbBlendOperation = .add
        rd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        rd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        rd.colorAttachments[0].alphaBlendOperation = .add
        rd.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        rd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pso = try? dev.makeRenderPipelineState(descriptor: rd) else { return nil }
        psoRender = pso

        let bufLen = MemoryLayout<GPUParticle>.stride * Self.maxParticles
        guard let pb = dev.makeBuffer(length: bufLen, options: .storageModeShared),
              let nb = dev.makeBuffer(length: MemoryLayout<Int32>.stride * Self.maxParticles,
                                      options: .storageModePrivate)
        else { return nil }
        self.particleBuffer = pb
        self.nextsBuffer = nb
        let p = pb.contents().bindMemory(to: GPUParticle.self, capacity: Self.maxParticles)
        for i in 0..<Self.maxParticles { p[i] = GPUParticle() }

        u.r = radius
        u.h = 2.0 * radius
        u.gravity = gravity
        u.friction = friction
    }

    private var liveCount: Int { min(writeIndex, Self.maxParticles) }

    private func ensureGrid(viewport: CGSize) {
        let gx = UInt32(max(1, ceil(Float(viewport.width) / u.h)))
        let gy = UInt32(max(1, ceil(Float(viewport.height) / u.h)))
        if gx != u.gridW || gy != u.gridH || headsBuffer == nil {
            u.gridW = gx
            u.gridH = gy
            let cells = Int(gx * gy)
            headsBuffer = device.makeBuffer(
                length: cells * MemoryLayout<Int32>.stride,
                options: .storageModePrivate
            )
        }
    }

    func viewportDidChange(to size: CGSize) {
        ensureGrid(viewport: size)
        wakeAll()
    }

    /// Wake every sleeping grain. Used on resize so settled piles fall to
    /// the new floor instead of hanging in the old position.
    private func wakeAll() {
        let p = particleBuffer.contents().bindMemory(to: GPUParticle.self, capacity: Self.maxParticles)
        for i in 0..<liveCount {
            if p[i].state == 3 { p[i].state = 2 }
        }
    }

    // MARK: - Input

    func spawn(string: String, rect: CGRect, font: NSFont, color: NSColor, decay: Float) {
        let pixels = GlyphRasterizer.pixels(for: string, rect: rect, font: font, color: color)
        guard !pixels.isEmpty else { return }
        let now = Float(CACurrentMediaTime())
        let p = particleBuffer.contents().bindMemory(to: GPUParticle.self, capacity: Self.maxParticles)
        let cc = color.usingColorSpace(.sRGB) ?? color
        let col = SIMD4<Float>(
            Float(cc.redComponent),
            Float(cc.greenComponent),
            Float(cc.blueComponent),
            1.0
        )
        let yMin = Float(rect.minY)
        let yMax = Float(rect.maxY)
        let yRange = max(yMax - yMin, 1)

        // Per-glyph cascade timing: each letter holds solid for most of the
        // decay budget, then collapses through a tight cascade window. The
        // `glyphHold` randomization spreads adjacent glyphs in time so a
        // paragraph doesn't dissolve as one wave.
        let glyphHold = decay * Float.random(in: 0.50...0.70)
        let cascade = decay * 0.30

        let start = writeIndex
        for px in pixels {
            let idx = writeIndex % Self.maxParticles
            var g = GPUParticle()
            g.pos = SIMD2(px.x, px.y)
            g.prev = g.pos
            g.color = col
            // Bottom-up bias inside the cascade window (pow > 1 so the
            // bottom row goes early and the rest follows in an accelerating
            // collapse). Small per-pixel noise lets a few grains break
            // ranks for an organic curtain.
            let yRel = (yMax - px.y) / yRange
            let cascadePos = pow(yRel, 1.6)
            let pixelNoise = decay * Float.random(in: -0.04...0.04)
            g.bornAt = now + max(0.05, glyphHold + cascadePos * cascade + pixelNoise)
            g.seed = Float.random(in: 0...1)
            g.state = 1
            p[idx] = g
            writeIndex += 1
        }
        glyphRanges.append(start..<writeIndex)
    }

    /// Lock the last `count` glyphs in place — they will not thaw on the
    /// normal decay schedule. Used for the "TNT" easter egg: the letters
    /// stay solid until the fuse blows them up.
    func markLastGlyphsAsTNT(count: Int) {
        guard count > 0 else { return }
        let p = particleBuffer.contents().bindMemory(to: GPUParticle.self, capacity: Self.maxParticles)
        let suffix = glyphRanges.suffix(count)
        for r in suffix {
            for i in r {
                let idx = i % Self.maxParticles
                if p[idx].state == 0 { continue }
                p[idx].state = 1
                p[idx].bornAt = .greatestFiniteMagnitude
                p[idx].prev = p[idx].pos
            }
        }
    }

    func undoLastGlyph() {
        guard let r = glyphRanges.popLast() else { return }
        let p = particleBuffer.contents().bindMemory(to: GPUParticle.self, capacity: Self.maxParticles)
        for i in r {
            p[i % Self.maxParticles].state = 0
        }
    }

    /// Arm a TNT at `center`. The engine handles its own 3-second fuse and
    /// fires `applyBlast` from `step()` when it expires. Multiple TNTs can
    /// be armed simultaneously; if one explosion's blast radius reaches
    /// another armed TNT, that one chains immediately.
    func armTNT(at center: CGPoint) {
        armedTNTs.append(ArmedTNT(
            pos: SIMD2(Float(center.x), Float(center.y)),
            endTime: CACurrentMediaTime() + tntFuse
        ))
    }

    /// Drive any armed TNTs whose fuses have run out, then chain-detonate
    /// any others their blast radius reaches.
    private func processTNTs(now: CFTimeInterval) {
        var queue: [SIMD2<Float>] = []
        var i = 0
        while i < armedTNTs.count {
            if armedTNTs[i].endTime <= now {
                queue.append(armedTNTs.remove(at: i).pos)
            } else {
                i += 1
            }
        }
        let r2 = tntRadius * tntRadius
        while let center = queue.popLast() {
            // Pull any other armed TNTs within blast radius into the queue.
            var j = 0
            while j < armedTNTs.count {
                let d = armedTNTs[j].pos - center
                if d.x * d.x + d.y * d.y < r2 {
                    queue.append(armedTNTs.remove(at: j).pos)
                } else {
                    j += 1
                }
            }
            applyBlast(at: center)
        }
    }

    private func applyBlast(at center: SIMD2<Float>) {
        let p = particleBuffer.contents().bindMemory(to: GPUParticle.self, capacity: Self.maxParticles)
        let r2 = tntRadius * tntRadius
        for i in 0..<liveCount {
            if p[i].state == 0 { continue }
            let d = p[i].pos - center
            let d2 = d.x * d.x + d.y * d.y
            if d2 < r2 {
                let dist = sqrt(d2)
                if dist < tntRadius * 0.35 {
                    p[i].state = 0
                    continue
                }
                let fall = (1 - dist / tntRadius)
                let push = fall * fall * tntForce
                var dir = dist > 0.001 ? d / dist : SIMD2<Float>(0, -1)
                dir.y -= 0.45
                let l = sqrt(dir.x * dir.x + dir.y * dir.y)
                dir /= l
                p[i].state = 2
                p[i].prev -= dir * push
            }
        }
    }

    // MARK: - Step + render

    func step(viewport: CGSize) {
        let now = CACurrentMediaTime()
        let frameDt = Float(min(max(now - lastFrameTime, 0.001), 0.05))
        lastFrameTime = now

        ensureGrid(viewport: viewport)
        u.viewport = SIMD2(Float(viewport.width), Float(viewport.height))
        u.count = UInt32(liveCount)
        u.now = Float(now)

        let cv = SIMD2<Float>(Float(cursor.x - lastCursor.x), Float(cursor.y - lastCursor.y))
        u.cursor = SIMD2(Float(cursor.x), Float(cursor.y))
        u.cursorVel = cv
        lastCursor = cursor

        processTNTs(now: now)

        // Heat tint follows the next-to-blow armed TNT.
        if let next = armedTNTs.min(by: { $0.endTime < $1.endTime }) {
            u.tntPos = next.pos
            u.tntT = Float(max(0, next.endTime - now))
        } else {
            u.tntT = 0
        }

        let count = liveCount
        guard count > 0, let heads = headsBuffer else { return }
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        let cellCount = Int(u.gridW * u.gridH)
        let particleTPG = MTLSize(width: 256, height: 1, depth: 1)
        let particleTG = MTLSize(width: (count + 255) / 256, height: 1, depth: 1)
        let cellTG = MTLSize(width: (cellCount + 255) / 256, height: 1, depth: 1)

        let subDt = frameDt / Float(substeps)

        for _ in 0..<substeps {
            u.dt = subDt

            // 1. clear grid
            enc.setComputePipelineState(psoClear)
            enc.setBuffer(heads, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<GPUUniforms>.stride, index: 1)
            enc.dispatchThreadgroups(cellTG, threadsPerThreadgroup: particleTPG)

            // 2. integrate
            enc.setComputePipelineState(psoIntegrate)
            enc.setBuffer(particleBuffer, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<GPUUniforms>.stride, index: 1)
            enc.dispatchThreadgroups(particleTG, threadsPerThreadgroup: particleTPG)

            // 3. build grid
            enc.setComputePipelineState(psoBuild)
            enc.setBuffer(particleBuffer, offset: 0, index: 0)
            enc.setBuffer(heads, offset: 0, index: 1)
            enc.setBuffer(nextsBuffer, offset: 0, index: 2)
            enc.setBytes(&u, length: MemoryLayout<GPUUniforms>.stride, index: 3)
            enc.dispatchThreadgroups(particleTG, threadsPerThreadgroup: particleTPG)

            // 4. solve
            enc.setComputePipelineState(psoSolve)
            enc.setBuffer(particleBuffer, offset: 0, index: 0)
            enc.setBuffer(heads, offset: 0, index: 1)
            enc.setBuffer(nextsBuffer, offset: 0, index: 2)
            enc.setBytes(&u, length: MemoryLayout<GPUUniforms>.stride, index: 3)
            enc.dispatchThreadgroups(particleTG, threadsPerThreadgroup: particleTPG)
        }

        // 5. sleep check (once per frame)
        enc.setComputePipelineState(psoSleep)
        enc.setBuffer(particleBuffer, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<GPUUniforms>.stride, index: 1)
        enc.dispatchThreadgroups(particleTG, threadsPerThreadgroup: particleTPG)

        enc.endEncoding()
        cmd.commit()
        // Intentionally no waitUntilCompleted — render queues after.
    }

    func encodeRender(into encoder: MTLRenderCommandEncoder) {
        let count = liveCount
        guard count > 0 else { return }
        encoder.setRenderPipelineState(psoRender)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<GPUUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
    }
}
