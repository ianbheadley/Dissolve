import AppKit

/// Freeform writing surface — no text storage; characters become particles.
final class Canvas: NSView {
    weak var settings: AppSettings?

    var onCharacter: ((String, CGRect, NSFont) -> Void)?
    var onResize: ((CGSize) -> Void)?
    var onDetonate: ((CGPoint) -> Void)?
    var onMarkTNT: ((Int) -> Void)?
    var onCursorMove: ((CGPoint?) -> Void)?

    private var caret: CGPoint = .zero
    private var lineOriginX: CGFloat = 32
    private var advanceHistory: [CGFloat] = []
    private let caretLayer = CALayer()
    private var placedCaret = false
    private var tntBuf: [Character] = []

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = false
        caretLayer.backgroundColor = NSColor.labelColor.cgColor
        layer?.addSublayer(caretLayer)
        startCaretBlink()
        let opts: NSTrackingArea.Options = [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    private var lineHeight: CGFloat {
        guard let f = settings?.font else { return 22 }
        return NSLayoutManager().defaultLineHeight(for: f)
    }
    private var caretRect: CGRect { CGRect(x: caret.x, y: caret.y, width: 1.5, height: lineHeight) }

    func placeInitialCaretIfNeeded() {
        guard !placedCaret, bounds.width > 0, bounds.height > 0 else { return }
        caret = CGPoint(x: 32, y: 36)
        lineOriginX = 32
        placedCaret = true
        bumpCaret()
    }

    private func startCaretBlink() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0; a.toValue = 0.0
        a.duration = 0.55
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        caretLayer.add(a, forKey: "blink")
    }

    private func bumpCaret() {
        guard let s = settings else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caretLayer.backgroundColor = s.inkColor.withAlphaComponent(0.85).cgColor
        caretLayer.frame = caretRect
        caretLayer.cornerRadius = 1
        CATransaction.commit()
        caretLayer.removeAnimation(forKey: "blink")
        startCaretBlink()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        caret = p
        lineOriginX = p.x
        advanceHistory.removeAll()
        bumpCaret()
        window?.makeFirstResponder(self)
    }
    override func mouseMoved(with e: NSEvent) { onCursorMove?(convert(e.locationInWindow, from: nil)) }
    override func mouseDragged(with e: NSEvent) { onCursorMove?(convert(e.locationInWindow, from: nil)) }
    override func mouseExited(with e: NSEvent) { onCursorMove?(nil) }

    override func setFrameSize(_ newSize: NSSize) {
        let old = bounds.size
        super.setFrameSize(newSize)
        if old != .zero, old != newSize { onResize?(newSize) }
        caret.x = min(max(caret.x, 4), max(newSize.width - 4, 4))
        caret.y = min(max(caret.y, 4), max(newSize.height - 4, 4))
        placeInitialCaretIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }

    override func insertText(_ insertString: Any) {
        let s = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        for c in s { commit(String(c)) }
    }
    override func insertNewline(_ sender: Any?) { wrapLine() }
    override func insertTab(_ sender: Any?) {
        guard let f = settings?.font else { return }
        let space = (" " as NSString).size(withAttributes: [.font: f]).width
        let adv = space * 4
        caret.x += adv
        advanceHistory.append(adv)
        if caret.x > bounds.width - 4 { wrapLine() }
        bumpCaret()
    }
    override func deleteBackward(_ sender: Any?) {
        guard let last = advanceHistory.popLast() else { return }
        caret.x = max(caret.x - last, lineOriginX)
        bumpCaret()
    }
    override func cancelOperation(_ sender: Any?) {
        lineOriginX = caret.x
        advanceHistory.removeAll()
        bumpCaret()
    }

    private func commit(_ ch: String) {
        guard let s = settings, !ch.isEmpty else { return }
        if ch == "\n" || ch == "\r" { wrapLine(); return }
        let f = s.font
        let adv = (ch as NSString).size(withAttributes: [.font: f]).width
        let h = NSLayoutManager().defaultLineHeight(for: f)
        if caret.x + adv > bounds.width - 4 { wrapLine() }
        let rect = CGRect(x: caret.x, y: caret.y, width: max(adv, 1), height: h)
        onCharacter?(ch, rect, f)
        caret.x += adv
        advanceHistory.append(adv)
        bumpCaret()

        if let c = ch.first { trackTNT(c, rect: rect) }
    }

    private func trackTNT(_ c: Character, rect: CGRect) {
        tntBuf.append(c)
        if tntBuf.count > 3 { tntBuf.removeFirst(tntBuf.count - 3) }
        if tntBuf == ["T", "N", "T"] {
            // Lock the three letters so they don't decay during the fuse.
            onMarkTNT?(3)
            onDetonate?(CGPoint(x: rect.midX, y: rect.midY))
            tntBuf.removeAll()
        }
    }

    private func wrapLine() {
        guard let s = settings else { return }
        let h = NSLayoutManager().defaultLineHeight(for: s.font)
        caret.y += h
        caret.x = lineOriginX
        if caret.y + h > bounds.height - 4 {
            caret.y = max(36, bounds.height * 0.05)
        }
        advanceHistory.removeAll()
        bumpCaret()
    }
}
