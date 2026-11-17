import SwiftUI

/// 配色。アイコンの色から取る。画面ごとに色を直書きしない
enum Theme {
    /// アイコンの羽の橙。主色
    static let accent = Color(red: 0xE9 / 255, green: 0x60 / 255, blue: 0x13 / 255)
    /// 録音と再生位置の赤
    static let live = Color.red
    /// 再生バーの波形。再生した分と残り
    static let played = live
    static let remaining = Color.primary.opacity(0.35)
    /// 文字起こしの話者
    static let partner = accent
    static let me = Color.green

    /// 並んで置くガラスの部品（文字のカプセル、アイコンのカプセル）の高さ。隣同士で揃える
    static let controlHeight: CGFloat = 36

    /// macOS 26 以降で Liquid Glass を使うか。スナップショット（オフスクリーン描画）は効果の層を写せないので、
    /// そのときだけ macOS 25 以前の見た目で描く
    @MainActor static var usesLiquidGlass = true
}

/// ガラスのカプセル。ホバーでわずかに大きくなり、押すと少し沈む。
/// macOS 26 以降は Liquid Glass（glassEffect）、それより前は素材と光沢で似せる
struct GlassCapsuleButtonStyle: ButtonStyle {
    enum Role {
        /// 主色で塗る。画面に 1 つの主な操作
        case prominent
        /// 素材だけの、周りに溶けるボタン
        case regular
    }
    var role: Role = .prominent

    func makeBody(configuration: Configuration) -> some View {
        Capsule(configuration: configuration, role: role)
    }

    private struct Capsule: View {
        let configuration: Configuration
        let role: Role
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            glass
                .contentShape(SwiftUI.Capsule())
                .scaleEffect(scale)
                .animation(reduceMotion ? nil : .spring(duration: 0.25), value: hovering)
                .animation(reduceMotion ? nil : .spring(duration: 0.15), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        @ViewBuilder
        private var glass: some View {
            if #available(macOS 26, *), Theme.usesLiquidGlass {
                // 影と押した反応はガラス自身が持つ。interactive() は Button がクリックを取るので付けず、
                // ホバーの拡大だけこちらで付ける（古い OS と同じ動き）
                label.glassEffect(role == .prominent ? .regular.tint(Theme.accent) : .regular, in: SwiftUI.Capsule())
            } else {
                label
                    .background {
                        ZStack {
                            SwiftUI.Capsule().fill(.regularMaterial)
                            if role == .prominent {
                                SwiftUI.Capsule().fill(Theme.accent.opacity(hovering ? 0.95 : 0.88))
                            } else {
                                SwiftUI.Capsule().fill(.primary.opacity(hovering ? 0.08 : 0.04))
                            }
                            GlassSheen(strong: role == .prominent)
                        }
                    }
                    .shadow(color: shadowColor, radius: hovering ? 12 : 6, y: 3)
            }
        }

        @ViewBuilder
        private var label: some View {
            switch role {
            case .prominent:
                configuration.label
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 16)
            case .regular:
                configuration.label
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .frame(height: Theme.controlHeight)
            }
        }

        private var shadowColor: Color {
            role == .prominent ? Theme.accent.opacity(hovering ? 0.45 : 0.3) : .black.opacity(hovering ? 0.18 : 0.12)
        }

        private var scale: CGFloat {
            if reduceMotion { return 1 }
            if configuration.isPressed { return 0.97 }
            return hovering ? 1.04 : 1
        }
    }
}

/// macOS 25 以前のガラスの光沢。上からの光と白い縁
private struct GlassSheen: View {
    var strong = false

    var body: some View {
        ZStack {
            Capsule().fill(
                LinearGradient(
                    colors: [.white.opacity(strong ? 0.25 : 0.18), .white.opacity(0.04), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            )
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(strong ? 0.7 : 0.45), .white.opacity(strong ? 0.15 : 0.08)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
            if !strong {
                // 明るい地でも縁が消えないように、下側に薄い影の線
                Capsule().strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
            }
        }
    }
}

/// アイコンのボタンを 1 つのガラスのカプセルに並べる
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .buttonStyle(GlassIconButtonStyle())
            .padding(.horizontal, 4)
            .frame(height: Theme.controlHeight)
            .glassCapsule()
    }
}

extension View {
    /// 押せない面（アイコンの台、検索欄）をガラスのカプセルに載せる
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26, *), Theme.usesLiquidGlass {
            GlassEffectContainer {
                glassEffect(.regular, in: Capsule())
            }
        } else {
            background {
                ZStack {
                    Capsule().fill(.regularMaterial)
                    Capsule().fill(.primary.opacity(0.04))
                    GlassSheen()
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
    }
}

/// カプセルの中のアイコン。ホバーで丸く明るくなる
struct GlassIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Icon(configuration: configuration)
    }

    private struct Icon: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .opacity(isEnabled ? 1 : 0.4)
                .frame(width: Theme.controlHeight - 4, height: Theme.controlHeight - 4)
                .background(Circle().fill(.primary.opacity(hovering && isEnabled ? 0.1 : 0)))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
                .contentShape(Circle())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// 録音の開始・停止ボタン。輪の中の赤い印が、ホバーでわずかに大きくなる
struct RecordButton: View {
    let recording: Bool
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.secondary.opacity(0.6), lineWidth: 2)
                    .frame(width: size, height: size)
                Group {
                    if recording {
                        RoundedRectangle(cornerRadius: size * 0.1).fill(Theme.live)
                            .frame(width: size * 0.4, height: size * 0.4)
                    } else {
                        Circle().fill(Theme.live)
                            .frame(width: size * 0.77, height: size * 0.77)
                    }
                }
                .scaleEffect(hovering && !reduceMotion ? 1.1 : 1)
                .animation(reduceMotion ? nil : .spring(duration: 0.2), value: hovering)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .onHover { hovering = $0 }
    }
}
