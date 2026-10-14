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

    /// Roxo para texto e contorno sobre fundo escuro (o roxo da marca fica apagado ali).
    static let brandPurpleLight = Color(red: 0x8F / 255, green: 0x8A / 255, blue: 0xFF / 255)

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
/// - `prominent`: roxo da marca (ação principal, ex.: Abduzir temporários)
/// - `outline`: contorno roxo (ação de apoio da marca, ex.: Abrir Disco)
/// - `secondary`: cinza do sistema (ex.: Monitor)
struct CapsuleLabel: View {
    enum Style { case prominent, outline, secondary }

    let title: String
    var systemImage: String?
    var style: Style = .prominent
    var fullWidth = false
    @Environment(\.colorScheme) private var colorScheme

    /// Roxo do texto/contorno: mais claro no modo escuro, para manter o contraste.
    private var ink: Color { colorScheme == .dark ? .brandPurpleLight : .brandPurple }

    init(title: String, systemImage: String? = nil, style: Style = .prominent, fullWidth: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.fullWidth = fullWidth
    }

    init(title: String, systemImage: String? = nil, prominent: Bool, fullWidth: Bool = false) {
        self.init(title: title, systemImage: systemImage, style: prominent ? .prominent : .secondary, fullWidth: fullWidth)
    }

    private var foreground: AnyShapeStyle {
        switch style {
        case .prominent: AnyShapeStyle(.white)
        case .outline: AnyShapeStyle(ink)
        case .secondary: AnyShapeStyle(.primary)
        }
    }

    private var fill: AnyShapeStyle {
        switch style {
        case .prominent: AnyShapeStyle(Color.brandPurple.gradient)
        case .outline: AnyShapeStyle(Color.brandPurple.opacity(0.08))
        case .secondary: AnyShapeStyle(.fill.secondary)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(foreground)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(fill)
                .overlay(Capsule().strokeBorder(ink, lineWidth: style == .outline ? 1.2 : 0))
        }
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
