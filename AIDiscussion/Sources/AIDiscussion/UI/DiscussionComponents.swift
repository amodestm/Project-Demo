import SwiftUI
import AIDiscussionCore

// MARK: - 颜色

extension Color {

    /// 从 hex 字符串生成颜色 (支持 #RRGGBB)。
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r, g, b: UInt64
        switch cleaned.count {
        case 6:
            r = value >> 16
            g = (value >> 8) & 0xFF
            b = value & 0xFF
        case 3:
            r = ((value >> 8) & 0xF) * 17
            g = ((value >> 4) & 0xF) * 17
            b = (value & 0xF) * 17
        default:
            r = 124; g = 156; b = 255
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }
}

// MARK: - 成员头像

/// 成员头像 —— 圆形渐变 + SF Symbol, 思考时右下角挂一个绿点。
struct AgentAvatar: View {

    let symbol: String
    let hex: String
    var size: CGFloat = 36
    var isThinking = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: hex), Color(hex: hex).opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)

            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
        }
        .overlay(alignment: .bottomTrailing) {
            if isThinking {
                Circle()
                    .fill(.green)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay(
                        Circle()
                            .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                    )
                    .offset(x: 1, y: 1)
            }
        }
    }
}

// MARK: - 思考中动画

/// 三个点依次脉冲 —— 表示"这个成员正在思考"。
struct TypingIndicator: View {

    var color: Color = .secondary

    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1.25 : 0.7)
                    .opacity(animating ? 1.0 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.16),
                        value: animating
                    )
            }
        }
        .frame(height: 14)
        .onAppear { animating = true }
    }
}

// MARK: - 发言气泡

/// 一条发言 —— 头像 + 名字 + 气泡。
///
/// 气泡底色取成员强调色的**低透明度版本**, 因此在浅色/深色外观下
/// 都能保持文字对比度, 同时每个成员一眼可分。
struct MessageBubble: View {

    let participant: DiscussionParticipant
    let text: String?
    var isThinking = false
    var roundTitle: String?

    private var accent: Color { Color(hex: participant.accentHex) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(
                symbol: participant.avatarSymbol,
                hex: participant.accentHex,
                isThinking: isThinking
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(participant.displayName)
                        .font(.caption.bold())
                        .foregroundStyle(accent)
                    if let roundTitle {
                        Text(roundTitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if isThinking {
                    HStack(spacing: 8) {
                        TypingIndicator(color: accent)
                        Text("正在组织观点与深入思考中…")
                            .font(.caption)
                            .foregroundStyle(accent.opacity(0.85))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                } else {
                    renderedText(text ?? "")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(bubbleBackground)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func renderedText(_ content: String) -> Text {
        if let attributed = try? AttributedString(markdown: content) {
            return Text(attributed)
        }
        return Text(content)
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(accent.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(accent.opacity(0.28), lineWidth: 1)
            )
    }
}

// MARK: - 决策卡片

/// 最终决策 —— 与发言气泡明显区分的金色卡片。
struct DecisionCard: View {

    let decision: String
    let moderatorName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                Text("最终决策")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Text("· \(moderatorName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(decision)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.45), lineWidth: 1.5)
        )
    }
}

// MARK: - 空状态

/// 讨论还没开始时的占位 —— 让成员"在场"但不发声。
struct DiscussionIdlePlaceholder: View {

    let participants: [DiscussionParticipant]

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: -8) {
                ForEach(Array(participants.prefix(5).enumerated()), id: \.element.id) { index, p in
                    AgentAvatar(symbol: p.avatarSymbol, hex: p.accentHex, size: 40)
                        .overlay(
                            Circle()
                                .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2.5)
                        )
                        .zIndex(Double(participants.count - index))
                }
            }

            Text("\(participants.count) 位成员已就位")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("点击「开始讨论」, 他们会按议程轮流发言并最终收敛出决策。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
