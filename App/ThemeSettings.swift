import SwiftUI

struct ReaderPalette: Sendable, Equatable {
    let lightText: String
    let lightBackground: String
    let darkText: String
    let darkBackground: String
    static func valid(_ value: String, fallback: String) -> String {
        value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) == nil ? fallback : value
    }
}

struct ThemeSettings: View {
    @AppStorage("lightText") private var lightText = "#202020"
    @AppStorage("lightBackground") private var lightBackground = "#FFFFFF"
    @AppStorage("darkText") private var darkText = "#DEDCD8"
    @AppStorage("darkBackground") private var darkBackground = "#181818"
    var body: some View {
        Section("Light theme") {
            ColorPicker("Text", selection: color($lightText), supportsOpacity: false)
            ColorPicker("Background", selection: color($lightBackground), supportsOpacity: false)
            preview(.light)
        }
        Section("Dark theme") {
            ColorPicker("Text", selection: color($darkText), supportsOpacity: false)
            ColorPicker("Background", selection: color($darkBackground), supportsOpacity: false)
            preview(.dark)
        }
        Section {
            Button("Reset theme colors") {
                lightText = "#202020"; lightBackground = "#FFFFFF"
                darkText = "#DEDCD8"; darkBackground = "#181818"
            }
            Text("The reader follows your device appearance. Colors are saved separately for each theme.").font(.caption)
        }
    }
    private func preview(_ scheme: ColorScheme) -> some View {
        ReaderThemePreview(
            palette: ReaderPalette(lightText: lightText, lightBackground: lightBackground,
                                   darkText: darkText, darkBackground: darkBackground),
            scheme: scheme
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private static func color(_ hex: String) -> Color {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    private func color(_ value: Binding<String>) -> Binding<Color> {
        Binding(get: { Self.color(value.wrappedValue) }, set: { color in
            let rgb = color.resolve(in: EnvironmentValues())
            func byte(_ component: Float) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
            value.wrappedValue = String(format: "#%02X%02X%02X", byte(rgb.red), byte(rgb.green), byte(rgb.blue))
        })
    }
}
