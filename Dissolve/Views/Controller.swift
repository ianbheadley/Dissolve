import AppKit
import MetalKit
import Combine

final class Controller: NSObject, MTKViewDelegate {
    let canvas: Canvas
    let metalView: MTKView
    let engine: Engine

    weak var settings: AppSettings?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        guard let e = Engine() else {
            fatalError("DissolveV2: Metal engine init failed")
        }
        self.engine = e
        self.canvas = Canvas(frame: .zero)

        let mv = PassThroughMetalView(frame: .zero, device: e.device)
        mv.framebufferOnly = true
        mv.colorPixelFormat = .bgra8Unorm
        mv.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mv.layer?.isOpaque = false
        mv.enableSetNeedsDisplay = false
        mv.isPaused = false
        mv.preferredFramesPerSecond = 60
        self.metalView = mv

        super.init()

        canvas.onCharacter = { [weak self] ch, rect, font in
            guard let s = self?.settings else { return }
            self?.engine.spawn(
                string: ch, rect: rect, font: font, color: s.inkColor,
                decay: Float(s.letterDecay)
            )
        }
        canvas.onResize = { [weak self] size in
            self?.engine.viewportDidChange(to: size)
        }
        canvas.onMarkTNT = { [weak self] count in
            self?.engine.markLastGlyphsAsTNT(count: count)
        }
        canvas.onDetonate = { [weak self] center in
            // Engine owns the fuse and chain logic.
            self?.engine.armTNT(at: center)
        }
        canvas.onCursorMove = { [weak self] pt in
            self?.engine.cursor = pt ?? CGPoint(x: -1e6, y: -1e6)
        }
        mv.delegate = self
    }

    func attach(settings: AppSettings) {
        self.settings = settings
        self.canvas.settings = settings
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.canvas.needsDisplay = true }
            .store(in: &cancellables)
    }

    func containerDidResize(to size: CGSize) {
        canvas.placeInitialCaretIfNeeded()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        engine.step(viewport: view.bounds.size)
        guard let desc = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = engine.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: desc) else { return }
        engine.encodeRender(into: enc)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

final class PassThroughMetalView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
