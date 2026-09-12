import SwiftUI

public enum SchneeSurfaceStyle: Sendable {
    case adaptive
    case deterministic
}

public struct SchneeSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    private let style: SchneeSurfaceStyle

    public init(style: SchneeSurfaceStyle) {
        self.style = style
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        switch style {
        case .adaptive:
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
            } else {
                content
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }
        case .deterministic:
            content
                .background(
                    deterministicBackground,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(deterministicBorder, lineWidth: 1)
                }
        }
    }

    private var deterministicBackground: Color {
        switch colorScheme {
        case .dark:
            Color(red: 0.12, green: 0.14, blue: 0.19)
        default:
            Color(red: 0.98, green: 0.99, blue: 1.00)
        }
    }

    private var deterministicBorder: Color {
        switch colorScheme {
        case .dark:
            .white.opacity(0.14)
        default:
            .black.opacity(0.10)
        }
    }
}

public extension View {
    func schneeSurface(_ style: SchneeSurfaceStyle = .adaptive) -> some View {
        modifier(SchneeSurfaceModifier(style: style))
    }
}
