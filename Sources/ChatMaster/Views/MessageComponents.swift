import LensCore
import MudsUI
import SwiftUI

/// Row used by search results and other message lists.
struct MessageRow: View {
    @EnvironmentObject var model: AppModel
    var message: LensMessage
    var showChat = true
    var selected = false
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(username: message.chat, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if showChat {
                        Text(model.displayName(message.chat))
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.chatTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if message.chat.hasSuffix("@chatroom") || !showChat || message.isSelf {
                        Text(model.senderLabel(message))
                            .font(DS.sub)
                            .foregroundStyle(DS.ink4)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    if message.isRecalled { RecallChip(message: message) }
                    if let a = model.analysisState(message.id)?.result {
                        Text("\(a.emoji) \(a.emotion)").font(DS.micro).foregroundStyle(Theme.valence(a.valence))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.valence(a.valence).opacity(0.12), in: Capsule())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    } else if model.analysisState(message.id)?.isLoading == true {
                        ThinkingOrb(size: 14)
                    }
                    Text(Fmt.smart(message.date))
                        .font(DS.micro.monospacedDigit())
                        .foregroundStyle(DS.ink5)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                HStack(alignment: .top, spacing: 7) {
                    if message.isTextual { SentimentDot(value: message.sentiment).padding(.top, 6) }
                    Text(message.text).font(DS.body).lineLimit(3).foregroundStyle(message.isTextual ? DS.ink2 : DS.ink5)
                }
                if let q = message.quote {
                    Text("↪︎ \(q)").font(DS.sub).foregroundStyle(DS.ink5).lineLimit(1)
                }
            }
            if message.isTextual {
                Button { model.inspect(message) } label: { Image(systemName: "sparkles") }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .opacity(hover || selected ? 1 : 0)
                    .help("分析情绪与意图")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(selected ? DS.card : (hover ? DS.wash : .clear), in: RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous).strokeBorder(selected ? DS.edge : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(DS.ease, value: hover)
        .contextMenu { MessageMenu(message: message) }
    }
}

struct MessageMenu: View {
    @EnvironmentObject var model: AppModel
    var message: LensMessage

    var body: some View {
        Button { model.inspect(message) } label: { Label("分析情绪与意图", systemImage: "sparkles") }
        Button { model.inspect(message, analyze: false); model.analyze(message, force: true) } label: {
            Label("重新分析", systemImage: "arrow.clockwise")
        }
        Divider()
        Button { model.openChat(message.chat, focusMessage: message) } label: {
            Label("打开会话", systemImage: "bubble.left.and.bubble.right")
        }
        Button { copyText(message.text); ToastCenter.shared.show(.success, "已复制", duration: 2) } label: {
            Label("复制文字", systemImage: "doc.on.doc")
        }
    }
}

struct RecallChip: View {
    var message: LensMessage
    var body: some View {
        Chip(text: "已撤回" + (message.recallDelay.map { " · \(Fmt.duration(Double($0)))后" } ?? ""), color: DS.warning)
            .help(message.recallNotice ?? "对方撤回了这条消息，ChatMaster 保留了原文")
    }
}

struct RecallBanner: View {
    var message: LensMessage
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill").font(.system(size: 18)).foregroundStyle(DS.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("这条消息已被撤回，以下为保留的原文").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.ink)
                if let at = message.recalledAt {
                    Text("撤回于 \(Fmt.smart(Date(timeIntervalSince1970: TimeInterval(at))))，发出 \(Fmt.duration(Double(message.recallDelay ?? 0)))后")
                        .font(DS.micro).foregroundStyle(DS.ink4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(DS.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous))
    }
}
