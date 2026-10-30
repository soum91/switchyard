import SwiftUI

enum Theme {
    /// Signal green: the "line clear" lamp on a railway switch.
    static let accent = Color(red: 0.24, green: 0.88, blue: 0.56)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let bgTop = Color(red: 0.05, green: 0.07, blue: 0.07)
    static let bgBottom = Color(red: 0.02, green: 0.02, blue: 0.02)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.08)
    static let good = Color(red: 0.35, green: 0.85, blue: 0.5)
    static let bad = Color(red: 1, green: 0.45, blue: 0.42)

    static var background: some View {
        ZStack {
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(0.14), .clear], center: .top, startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

struct CardTitle: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text.uppercased(), systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.55))
    }
}

struct SignalBars: View {
    let bars: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? Color.white : Color.white.opacity(0.2))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
    }
}
