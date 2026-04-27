import SwiftUI
import AppKit

final class AppSettings: ObservableObject {
    private static let d = UserDefaults.standard

    @Published var fontSize: Double { didSet { Self.d.set(fontSize, forKey: K.fontSize) } }
    @Published var fontName: String { didSet { Self.d.set(fontName, forKey: K.fontName) } }
    @Published var backgroundHex: String { didSet { Self.d.set(backgroundHex, forKey: K.bg) } }
    @Published var inkHex: String { didSet { Self.d.set(inkHex, forKey: K.ink) } }
    @Published var letterDecay: Double { didSet { Self.d.set(letterDecay, forKey: K.letterDecay) } }

    init() {
        let d = Self.d
        self.fontSize = (d.object(forKey: K.fontSize) as? Double) ?? 26.0
        self.fontName = (d.string(forKey: K.fontName)) ?? "Iowan Old Style"
        self.backgroundHex = (d.string(forKey: K.bg)) ?? "#0E0E10"
        self.inkHex = (d.string(forKey: K.ink)) ?? "#E8E4DA"
        self.letterDecay = (d.object(forKey: K.letterDecay) as? Double) ?? 5.0
    }

    var backgroundColor: NSColor { NSColor(hex: backgroundHex) ?? .black }
    var inkColor: NSColor { NSColor(hex: inkHex) ?? .white }

    /// SwiftUI bindings: `ColorPicker` writes here, the hex string follows.
    var backgroundSwiftUI: Color {
        get { Color(nsColor: backgroundColor) }
        set { backgroundHex = NSColor(newValue).hexString }
    }
    var inkSwiftUI: Color {
        get { Color(nsColor: inkColor) }
        set { inkHex = NSColor(newValue).hexString }
    }

    var font: NSFont {
        NSFont(name: fontName, size: CGFloat(fontSize))
            ?? NSFont.systemFont(ofSize: CGFloat(fontSize))
    }

    private enum K {
        static let fontSize = "v2.fontSize"
        static let fontName = "v2.fontName"
        static let bg = "v2.bg"
        static let ink = "v2.ink"
        static let letterDecay = "v2.letterDecay"
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    private static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            Section("Type") {
                Picker("Font", selection: $settings.fontName) {
                    ForEach(Self.fontFamilies, id: \.self) { name in
                        Text(name)
                            .font(.custom(name, size: 13))
                            .tag(name)
                    }
                }
                Slider(value: $settings.fontSize, in: 14...60) { Text("Size") }
            }
            Section("Decay") {
                Slider(value: $settings.letterDecay, in: 3...120) { Text("Time") }
                Text(decayLabel(settings.letterDecay))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Surface") {
                ColorPicker("Background",
                            selection: Binding(
                                get: { settings.backgroundSwiftUI },
                                set: { settings.backgroundSwiftUI = $0 }
                            ),
                            supportsOpacity: false)
                ColorPicker("Ink",
                            selection: Binding(
                                get: { settings.inkSwiftUI },
                                set: { settings.inkSwiftUI = $0 }
                            ),
                            supportsOpacity: false)
            }
        }
        .padding(16)
    }

    private func decayLabel(_ s: Double) -> String {
        if s < 60 {
            return s < 10 ? String(format: "%.1f s", s) : String(format: "%.0f s", s)
        }
        let m = Int(s) / 60
        let r = Int(s) % 60
        return r == 0 ? "\(m) min" : "\(m) min \(r) s"
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(
            red: CGFloat((v & 0xFF0000) >> 16) / 255,
            green: CGFloat((v & 0x00FF00) >> 8) / 255,
            blue: CGFloat(v & 0x0000FF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
