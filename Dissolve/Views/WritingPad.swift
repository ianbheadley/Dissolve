import SwiftUI
import AppKit
import MetalKit

struct WritingPad: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        PadRepresentable()
            .environmentObject(settings)
            .background(Color(nsColor: settings.backgroundColor))
            .ignoresSafeArea()
    }
}

private struct PadRepresentable: NSViewRepresentable {
    @EnvironmentObject var settings: AppSettings

    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> PadContainer {
        let c = Controller()
        c.attach(settings: settings)
        context.coordinator.controller = c
        let v = PadContainer(controller: c)
        v.wantsLayer = true
        v.updateAppearance(settings)
        DispatchQueue.main.async { v.window?.makeFirstResponder(c.canvas) }
        return v
    }

    func updateNSView(_ nsView: PadContainer, context: Context) {
        nsView.updateAppearance(settings)
    }

    final class Coord {
        var controller: Controller?
    }
}

final class PadContainer: NSView {
    let controller: Controller
    init(controller: Controller) {
        self.controller = controller
        super.init(frame: .zero)
        layer = CALayer()
        layer?.masksToBounds = true
        addSubview(controller.canvas)
        addSubview(controller.metalView)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layer?.frame = bounds
        controller.canvas.frame = bounds
        controller.metalView.frame = bounds
        controller.containerDidResize(to: bounds.size)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(controller.canvas)
    }
    func updateAppearance(_ s: AppSettings) {
        layer?.backgroundColor = s.backgroundColor.cgColor
    }
}
