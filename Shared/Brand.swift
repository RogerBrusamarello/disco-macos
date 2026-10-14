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

/// Cápsula padrão do disco, igual no widget, no popover e na janela.
/// `prominent`: roxo da marca (ação principal, ex.: Abduzir temporários); senão, cinza do sistema.
struct CapsuleLabel: View {
    let title: String
    var systemImage: String?
    var prominent = true
    var fullWidth = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
        }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                prominent ? AnyShapeStyle(Color.brandPurple.gradient) : AnyShapeStyle(.fill.secondary),
                in: Capsule()
            )
            .contentShape(Capsule())
    }
}

/// Feedback de clique e estado desabilitado para botões com `CapsuleLabel`.
struct CapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
