import LensCore
import MudsUI
import SwiftUI

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

struct RecallsView: View {
    @EnvironmentObject var model: AppModel
    @State private var items: [LensMessage] = []
    @State private var filter = ""
    @State private var scope: Scope = .others

    enum Scope: Hashable { case others, all }

    private var shown: [LensMessage] {
        items.filter { m in
            (scope == .all || !m.isSelf) && (filter.isEmpty || m.text.localizedCaseInsensitiveContains(filter)
                || model.displayName(m.chat).localizedCaseInsensitiveContains(filter)
                || model.senderLabel(m).localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "防撤回", subtitle: "保留被撤回消息的原文 · 共 \(shown.count) 条") {
                HStack(spacing: 8) {
                    FilterField(text: $filter, prompt: "筛选人、群或内容").frame(width: 220)
                    BSegmented(selection: $scope, options: [(.others, "别人撤回"), (.all, "全部")])
                }
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(shown) { m in
                        RecallRow(message: m, selected: model.inspected?.id == m.id)
                            .onTapGesture { model.inspect(m, analyze: false) }
                            .contextMenu { MessageMenu(message: m) }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
            .overlay {
                if shown.isEmpty {
                    EmptyHint(title: "还没有拦截到撤回", systemImage: "arrow.uturn.backward.circle",
                              detail: "ChatMaster 运行时，别人撤回的消息会保留原文并出现在这里。打开应用之前撤回的消息无法恢复。")
                }
            }
        }
        .task(id: model.revision) {
            guard let store = model.store else { return }
            let r = await Task.detached { store.recalledMessages() }.value
            withAnimation(DS.spring) { items = r }
        }
    }
}

struct RecallRow: View {
    @EnvironmentObject var model: AppModel
    var message: LensMessage
    var selected = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(username: message.isSelf ? (model.store?.selfUsername ?? "") : (message.sender ?? message.chat), size: 38)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(model.senderLabel(message)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.ink)
                    if message.chat.hasSuffix("@chatroom") {
                        Text(model.displayName(message.chat)).font(DS.sub).foregroundStyle(DS.ink4).lineLimit(1)
                    }
                    Spacer()
                    RecallChip(message: message)
                    if let at = message.recalledAt {
                        Text(Fmt.smart(Date(timeIntervalSince1970: TimeInterval(at)))).font(DS.micro.monospacedDigit())
                            .foregroundStyle(DS.ink5)
                    }
                }
                if let q = message.quote { Text("↪︎ \(q)").font(DS.sub).foregroundStyle(DS.ink5).lineLimit(1) }
                Text(message.text).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(message.isTextual ? DS.ink : DS.ink4)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DS.warning.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                HStack(spacing: 6) {
                    if message.isTextual {
                        Button { model.inspect(message) } label: { Label("分析", systemImage: "sparkles") }
                            .buttonStyle(BButtonStyle(kind: .primary, compact: true))
                    }
                    Button { copyText(message.text); ToastCenter.shared.show(.success, "已复制原文", duration: 2) } label: {
                        Label("复制原文", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                    Button { model.openChat(message.chat) } label: { Label("打开会话", systemImage: "bubble.left.and.bubble.right") }
                        .buttonStyle(BButtonStyle(kind: .ghost, compact: true))
                }
            }
        }
        .padding(16)
        .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(selected ? DS.pick.opacity(0.6) : DS.edge,
                                                                                            lineWidth: selected ? 1.5 : 1))
    }
}
