import SwiftUI

/// Nino Voice notch palette. This must track ~/dev/nino-os/components/studio/tokens.ts.
enum NinoPalette {
    static let ink = color(0x070609)
    static let surface = color(0x0C0B0F)
    static let surface2 = color(0x131218)
    static let surface3 = color(0x1B1A22)
    static let gold = color(0xD4A853)
    static let gold2 = color(0xEED08A)
    static let goldDim = color(0x9C7628)
    static let cream = color(0xF6F3EC)
    static let creamDim = cream.opacity(0.56)
    static let border = gold.opacity(0.14)

    private static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
