import SwiftUI

/// Paleta da identidade (brand/icon-1024.png).
extension Color {
    /// Aba do disco voador
    static let brandPurple = Color(red: 0x53 / 255, green: 0x4D / 255, blue: 0xFC / 255)
    /// Sombra da aba
    static let brandIndigo = Color(red: 0x3F / 255, green: 0x3C / 255, blue: 0xE9 / 255)
    /// Cúpula
    static let brandCyan = Color(red: 0x85 / 255, green: 0xE8 / 255, blue: 0xFD / 255)
    /// Feixe
    static let brandMint = Color(red: 0x52 / 255, green: 0xE5 / 255, blue: 0xD5 / 255)

    /// Disco: roxo do disco voador; vermelho acima de 90%.
    static func diskTint(_ fraction: Double) -> Color { fraction < 0.9 ? .brandPurple : .red }

    /// Memória: menta do feixe; laranja/vermelho conforme a pressão.
    static func memoryTint(_ pressure: Int32) -> Color {
        switch pressure {
        case 4: .red
        case 2: .orange
        default: .brandMint
        }
    }
}
