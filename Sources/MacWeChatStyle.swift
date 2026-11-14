import AppKit
import SwiftUI

enum MacWeChatStyle {
    static let accent = adaptive(0x08753D, 0x76D6A1)
    static let action = Color(red: 0.05, green: 0.48, blue: 0.25)
    static let rail = adaptive(0xEAF5EE, 0x1C2822)
    static let panel = adaptive(0xFFFFFF, 0x242A28)
    static let surface = adaptive(0xF3F6F5, 0x191E1C)
    static let field = adaptive(0xEEF2F0, 0x303A35)
    static let selection = adaptive(0xDEF2E6, 0x314D3E)
    static let outgoingBubble = adaptive(0xE0F5DA, 0x2A4937)
    static let border = adaptive(0xDDE6E0, 0x3B4841)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                           green: Double((rgb >> 8) & 255) / 255,
                           blue: Double(rgb & 255) / 255, alpha: 1)
        })
    }
}

struct MacWeChatIconButton: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .frame(width: 34, height: 34)
            .foregroundStyle(selected ? MacWeChatStyle.accent : Color.secondary)
            .background(selected || configuration.isPressed ? MacWeChatStyle.selection : .clear, in: Circle())
            .contentShape(Circle())
    }
}

struct MacWeChatAvatar<Content: View>: View {
    let size: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().frame(width: size, height: size).clipShape(Circle())
    }
}

struct MacWeChatBubble<Content: View>: View {
    let outgoing: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(outgoing ? MacWeChatStyle.outgoingBubble : MacWeChatStyle.panel,
                        in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(MacWeChatStyle.border.opacity(0.7)))
    }
}
