import SwiftUI

enum MessagesStyle {
    static let accent = Color(red: 0.20, green: 0.51, blue: 0.98)
    static let incoming = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGray5 : UIColor(red: 233 / 255, green: 233 / 255, blue: 234 / 255, alpha: 1)
    })
    static let outgoing = Color(red: 0.32, green: 0.63, blue: 0.96)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let surface = Color(uiColor: .systemBackground)
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .secondarySystemBackground : UIColor(red: 238 / 255, green: 238 / 255, blue: 240 / 255, alpha: 1)
    })
    static let mute = Color(red: 0.37, green: 0.28, blue: 0.94)
}

struct AvatarView: View {
    let asset: String
    let size: CGFloat

    var body: some View {
        Group {
            if UIImage(named: asset) != nil {
                Image(asset).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(MessagesStyle.accent)
                    .background(MessagesStyle.card)
            }
        }
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: asset == "apple" || asset == "myprotein" ? size * 0.22 : size / 2))
            .accessibilityHidden(true)
    }
}

struct GlassIconButton: View {
    let symbol: String
    let label: LocalizedStringResource
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(Text(label))
    }
}

struct GlassTextButton: View {
    let title: LocalizedStringResource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

extension ChatBackground {
    var color: Color {
        switch self {
        case .plain: MessagesStyle.surface
        case .sky: Color(red: 0.91, green: 0.96, blue: 1)
        case .rose: Color(red: 1, green: 0.94, blue: 0.95)
        case .sage: Color(red: 0.92, green: 0.97, blue: 0.93)
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .plain: "native.background.plain"
        case .sky: "native.background.sky"
        case .rose: "native.background.rose"
        case .sage: "native.background.sage"
        }
    }
}
