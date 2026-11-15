import SwiftUI

/// Near-black, one warm accent, small calm type. Every color is defined here.
enum Theme {
    static let background = Color(red: 0.047, green: 0.051, blue: 0.059)      // #0C0D0F
    static let card = Color(red: 0.082, green: 0.086, blue: 0.098)            // #15161A
    static let cardRaised = Color(red: 0.106, green: 0.110, blue: 0.125)      // #1B1C20
    static let menu = Color(red: 0.110, green: 0.114, blue: 0.129)            // #1C1D21
    static let hairline = Color.white.opacity(0.08)
    static let hairlineStrong = Color.white.opacity(0.14)
    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.56)
    static let tertiary = Color.white.opacity(0.34)
    static let accent = Color(red: 0.918, green: 0.471, blue: 0.318)          // warm coral #EA7851
    static let good = Color(red: 0.494, green: 0.820, blue: 0.580)
    static let warn = Color(red: 0.949, green: 0.769, blue: 0.392)
    static let bad = Color(red: 0.937, green: 0.427, blue: 0.427)

    static let body = Font.system(size: 12.5)
    static let small = Font.system(size: 11)
    static let tiny = Font.system(size: 10)
    static let mono = Font.system(size: 11.5, design: .monospaced)
    static let monoSmall = Font.system(size: 10.5, design: .monospaced)
    static let title = Font.system(size: 15, weight: .medium)
    static let headline = Font.system(size: 20, weight: .semibold)

    static let radius: CGFloat = 14
    static let chipRadius: CGFloat = 7
}

extension View {
    /// The floating-card look: raised fill, hairline border, soft shadow.
    func cardStyle(radius: CGFloat = Theme.radius, fill: Color = Theme.card) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }
}

/// Small rounded "chip" button, as in the composer row.
struct Chip<Label: View>: View {
    var isOpen = false
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { label() }
                .font(Theme.small)
                .foregroundStyle(isOpen || hover ? Theme.text : Theme.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                    .fill(isOpen ? Color.white.opacity(0.09) : (hover ? Color.white.opacity(0.05) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A row inside a floating menu.
struct MenuRow<Trailing: View>: View {
    var icon: String?
    var iconColor: Color = Theme.accent
    var title: String
    var subtitle: String?
    var selected = false
    var action: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: subtitle == nil ? .center : .top, spacing: 9) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(iconColor)
                        .frame(width: 14).padding(.top, subtitle == nil ? 0 : 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.body).foregroundStyle(Theme.text)
                    if let subtitle { Text(subtitle).font(Theme.tiny).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 12)
                trailing()
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Color.white.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

extension MenuRow where Trailing == EmptyView {
    init(icon: String? = nil, iconColor: Color = Theme.accent, title: String, subtitle: String? = nil, selected: Bool = false,
         action: @escaping () -> Void) {
        self.init(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle, selected: selected, action: action) { EmptyView() }
    }
}

/// Floating menu panel.
struct MenuPanel<Content: View>: View {
    var width: CGFloat = 260
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) { content() }
            .padding(5)
            .frame(width: width, alignment: .leading)
            .cardStyle(radius: 11, fill: Theme.menu)
    }
}

struct MenuDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6) }
}

struct MenuSectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9.5, weight: .medium)).tracking(0.6)
            .foregroundStyle(Theme.tertiary).padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 2)
    }
}

/// `Standard | ⚡ Fast`-style segmented control.
struct Segmented<T: Hashable>: View {
    var options: [(T, String, String?)]  // value, title, SF symbol
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title, icon) = options[i]
                let on = value == selection
                Button { selection = value } label: {
                    HStack(spacing: 3) {
                        if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
                        Text(title)
                    }
                    .font(Theme.small)
                    .foregroundStyle(on ? Theme.text : Theme.secondary)
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.white.opacity(0.11) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Plain text button with a hairline outline; `prominent` fills it with the accent.
struct PillButton: View {
    var title: String
    var icon: String?
    var prominent = false
    var disabled = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : Theme.text)
            .padding(.horizontal, 11).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(prominent ? Theme.accent.opacity(hover ? 1 : 0.92) : Color.white.opacity(hover ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(prominent ? .clear : Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hover = $0 }
    }
}

func formatTPS(_ v: Double?) -> String {
    guard let v else { return "–" }
    return v >= 1000 ? String(format: "%.0f", v) : (v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v))
}

func formatBytes(_ b: UInt64) -> String { fmtBytes(b) }

func formatDuration(_ s: Double) -> String {
    if s < 60 { return "\(Int(s.rounded())) s" }
    let m = Int((s / 60).rounded())
    return m < 60 ? "\(m) min" : String(format: "%.1f h", s / 3600)
}

import ZoomiesKit
