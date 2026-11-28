import LensCore
import MudsUI
import SwiftUI

/// Single-message analysis card (used in the inspector, the WeChat sidebar and the popup).
struct MessageAnalysisCard: View {
    var analysis: MessageAnalysis
    var compact = false
    var onFillReply: ((String) -> Void)? = nil
    @State private var popped = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            header
            HStack(spacing: 10) {
                Text("强度").font(DS.micro).foregroundStyle(DS.ink4).lineLimit(1)
                IntensityDots(value: analysis.intensity, color: Theme.valence(analysis.valence))
                Spacer(minLength: 4)
                if analysis.needsReply {
                    Chip(text: "需回复 · \(analysis.urgency)", color: Theme.urgency(analysis.urgency), filled: analysis.urgency == "高")
                } else {
                    Chip(text: "无需回复")
                }
                Text("置信 \(Int(analysis.confidence * 100))%")
                    .font(DS.micro.monospacedDigit())
                    .foregroundStyle(DS.ink5)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if !analysis.subtext.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Caption(title: "潜台词", icon: "quote.opening")
                    Text(analysis.subtext)
                        .font(compact ? DS.body : .system(size: 14.5))
                        .foregroundStyle(DS.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Capsule().fill(DS.pick).frame(width: 2.5) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Caption(title: "意图", icon: "scope")
                FlowLayout(spacing: 6) {
                    Chip(text: analysis.intent, filled: true)
                    ForEach(analysis.toneTags.filter { $0 != analysis.intent }.prefix(4), id: \.self) { Chip(text: $0) }
                }
                if !analysis.intentDetail.isEmpty {
                    Text(analysis.intentDetail).font(DS.body).foregroundStyle(DS.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !analysis.risks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Caption(title: "注意", icon: "exclamationmark.triangle")
                    ForEach(analysis.risks, id: \.self) { r in
                        Label(r, systemImage: "circle.fill").labelStyle(BulletLabelStyle(color: DS.warning)).font(DS.body)
                    }
                }
            }
            if !analysis.replySuggestions.isEmpty {
                ReplySuggestionsBlock(suggestions: analysis.replySuggestions, onFillReply: onFillReply)
            }
            if !analysis.evidence.isEmpty && !compact {
                Text("依据：\(analysis.evidence)").font(DS.sub).foregroundStyle(DS.ink5).fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(analysis.emoji)
                .font(.system(size: compact ? 26 : 32))
                .frame(width: compact ? 46 : 56, height: compact ? 46 : 56)
                .background(Theme.valence(analysis.valence).opacity(0.14), in: Circle())
                .scaleEffect(popped ? 1 : 0.5)
                .onAppear { withAnimation(DS.bouncy) { popped = true } }
            VStack(alignment: .leading, spacing: 5) {
                Text(analysis.emotion)
                    .font(.system(size: compact ? 17 : 21, weight: .semibold)).tracking(-0.3)
                    .foregroundStyle(DS.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if !analysis.secondaryEmotions.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(analysis.secondaryEmotions.prefix(3), id: \.self) { Chip(text: $0) }
                    }
                }
            }
            Spacer(minLength: 4)
            ArcGauge(value: analysis.valence, size: compact ? 64 : 76)
        }
    }
}

/// Loading / error / result wrapper for a message.
struct MessageAnalysisSlot: View {
    @EnvironmentObject var model: AppModel
    var message: LensMessage
    var compact = false
    var onFillReply: ((String) -> Void)? = nil

    var body: some View {
        Group {
            switch model.analysisState(message.id) {
            case .none:
                Button { model.analyze(message) } label: {
                    HStack(spacing: 8) {
                        ThinkingOrb(size: 16, active: false)
                        Text("分析情绪与意图")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(BButtonStyle(kind: .primary))
            case .loading(let since):
                AnalyzingView(since: since, label: "agy 正在分析…")
            case .failed(let err):
                VStack(alignment: .leading, spacing: 8) {
                    Label("分析失败", systemImage: "xmark.octagon.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.error)
                    Text(err).font(DS.sub).foregroundStyle(DS.ink4).textSelection(.enabled)
                    Button("重试") { model.analyze(message, force: true) }.buttonStyle(BButtonStyle(compact: true))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.error.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous))
            case .done(let a):
                VStack(alignment: .leading, spacing: 10) {
                    MessageAnalysisCard(analysis: a, compact: compact, onFillReply: onFillReply)
                    HStack {
                        Spacer()
                        Button { model.analyze(message, force: true) } label: { Label("重新分析", systemImage: "arrow.clockwise") }
                            .buttonStyle(BButtonStyle(kind: .ghost, compact: true))
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(DS.spring, value: model.analysisState(message.id)?.isLoading)
    }
}

// MARK: - Conversation / relationship cards

struct BulletList: View {
    var title: String
    var icon: String
    var items: [String]
    var color: Color = DS.ink5

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Caption(title: title, icon: icon)
                ForEach(items, id: \.self) { Label($0, systemImage: "circle.fill").labelStyle(BulletLabelStyle(color: color)).font(DS.body) }
            }
        }
    }
}

struct ConversationAnalysisCard: View {
    var analysis: ConversationAnalysis
    var onFillReply: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FlowLayout(spacing: 6) {
                if !analysis.overallMood.isEmpty { Chip(text: analysis.overallMood, filled: true) }
                if !analysis.moodTrend.isEmpty { Chip(text: analysis.moodTrend, color: DS.pick) }
                ForEach(analysis.topics.prefix(4), id: \.self) { Chip(text: "#\($0)") }
            }
            Text(analysis.summary).font(.system(size: 14)).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
            if !analysis.myState.isEmpty || !analysis.theirState.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    statePanel("我", analysis.myState)
                    statePanel("对方", analysis.theirState)
                }
            }
            BulletList(title: "关键信息", icon: "pin", items: analysis.keyPoints)
            if !analysis.myTodos.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Caption(title: "我要做的", icon: "checklist")
                    ForEach(analysis.myTodos, id: \.self) { ChecklistRow(text: $0).font(DS.body) }
                }
            }
            BulletList(title: "对方要做的", icon: "person.badge.clock", items: analysis.theirTodos, color: DS.pick)
            BulletList(title: "未解决的问题", icon: "questionmark.bubble", items: analysis.openQuestions, color: DS.warning)
            BulletList(title: "风险", icon: "exclamationmark.triangle", items: analysis.risks, color: DS.error)
            if !analysis.suggestedNextStep.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.forward.circle.fill").foregroundStyle(DS.pick)
                    Text(analysis.suggestedNextStep).font(DS.body).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.pick.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous))
            }
            if !analysis.replySuggestions.isEmpty {
                ReplySuggestionsBlock(suggestions: analysis.replySuggestions, onFillReply: onFillReply)
            }
        }
        .textSelection(.enabled)
    }

    private func statePanel(_ who: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(who).font(DS.micro).foregroundStyle(DS.ink4)
            Text(text.isEmpty ? "—" : text).font(DS.body).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(DS.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct RelationshipReportCard: View {
    var report: RelationshipReport
    @State private var width: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Chip(text: report.closenessLabel.isEmpty ? "关系" : report.closenessLabel, filled: true)
                HStack(spacing: 3) {
                    ForEach(1...5, id: \.self) { i in
                        Capsule().fill(i <= report.closeness ? Color(muHex: 0xF43F5E) : DS.wash2).frame(width: 14, height: 6)
                    }
                }
                .help("亲密度 \(report.closeness)/5")
                Spacer()
            }
            FlowLayout(spacing: 6) { ForEach(report.recurringTopics.prefix(6), id: \.self) { Chip(text: "#\($0)") } }
            Text(report.summary).font(.system(size: 14)).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                row("互动", report.dynamics)
                row("对方", report.theirStyle)
                row("我", report.myStyle)
            }
            if width > 0 && width < 420 {
                VStack(alignment: .leading, spacing: 14) {
                    BulletList(title: "亮点", icon: "sparkles", items: report.strengths, color: DS.ok)
                    BulletList(title: "摩擦", icon: "bolt", items: report.frictions, color: DS.warning)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    BulletList(title: "亮点", icon: "sparkles", items: report.strengths, color: DS.ok)
                    BulletList(title: "摩擦", icon: "bolt", items: report.frictions, color: DS.warning)
                }
            }
            if !report.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Caption(title: "建议", icon: "lightbulb")
                    ForEach(report.suggestions, id: \.self) { ChecklistRow(text: $0).font(DS.body) }
                }
            }
        }
        .textSelection(.enabled)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k).font(DS.micro).foregroundStyle(DS.ink4).lineLimit(1).frame(width: 30, alignment: .leading).padding(.top, 2)
            Text(v).font(DS.body).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(DS.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct GroupAnalysisCard: View {
    var analysis: GroupAnalysis
    var onSelectMemberName: ((String) -> Void)?
    var onFillReply: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowLayout(spacing: 6) {
                if !analysis.atmosphere.isEmpty { Chip(text: analysis.atmosphere, filled: true) }
                ForEach(analysis.topics.prefix(4), id: \.self) { Chip(text: "#\($0)") }
            }

            if !analysis.summary.isEmpty {
                Text(analysis.summary)
                    .font(DS.body)
                    .foregroundStyle(DS.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !analysis.mentionsMe.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Caption(title: "与我相关", icon: "at")
                    ForEach(analysis.mentionsMe, id: \.self) { item in
                        Label(item, systemImage: "circle.fill")
                            .labelStyle(BulletLabelStyle(color: DS.warning))
                            .font(DS.sub)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }

            if !analysis.members.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Caption(title: "分人洞察", icon: "person.2")
                    ForEach(analysis.members, id: \.self) { member in
                        Button {
                            onSelectMemberName?(member.name)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(member.emoji.isEmpty ? "🙂" : member.emoji).font(.system(size: 13))
                                    Text(member.name)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(Theme.chatTitle)
                                        .lineLimit(1)
                                    if !member.role.isEmpty {
                                        Chip(text: member.role)
                                    }
                                    Spacer(minLength: 4)
                                    if !member.mood.isEmpty {
                                        Text(member.mood)
                                            .font(DS.micro)
                                            .foregroundStyle(DS.ink4)
                                            .lineLimit(1)
                                    }
                                }
                                if !member.stance.isEmpty {
                                    Text(member.stance)
                                        .font(DS.sub)
                                        .foregroundStyle(DS.ink2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                }
                                if !member.intent.isEmpty {
                                    Text("意图：\(member.intent)")
                                        .font(DS.micro)
                                        .foregroundStyle(DS.ink4)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.edge, lineWidth: 0.75))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(onSelectMemberName == nil)
                    }
                }
            }

            BulletList(title: "结论与待办", icon: "pin", items: analysis.decisions)

            if !analysis.suggestedNextStep.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.forward.circle.fill").foregroundStyle(DS.pick)
                    Text(analysis.suggestedNextStep).font(DS.sub).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.pick.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }

            if !analysis.replySuggestions.isEmpty {
                ReplySuggestionsBlock(suggestions: analysis.replySuggestions, onFillReply: onFillReply)
            }
        }
        .textSelection(.enabled)
    }
}

struct GroupMemberAnalysisCard: View {
    var analysis: GroupMemberAnalysis
    var onFillReply: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(analysis.emoji.isEmpty ? "😐" : analysis.emoji)
                    .font(.system(size: 22))
                    .frame(width: 38, height: 38)
                    .background(DS.pick.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(analysis.memberName.isEmpty ? "群成员" : analysis.memberName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                        if !analysis.role.isEmpty { Chip(text: analysis.role) }
                    }
                    if !analysis.mood.isEmpty {
                        Text(analysis.mood).font(DS.micro).foregroundStyle(DS.ink4).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if !analysis.stance.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Caption(title: "核心立场", icon: "scope")
                    Text(analysis.stance).font(DS.sub).foregroundStyle(DS.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !analysis.subtext.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Caption(title: "潜台词", icon: "quote.opening")
                    Text(analysis.subtext)
                        .font(DS.sub)
                        .foregroundStyle(DS.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Capsule().fill(DS.pick).frame(width: 2) }
                }
            }

            if !analysis.interactionWithMe.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Caption(title: "与我互动", icon: "person.2")
                    Text(analysis.interactionWithMe).font(DS.sub).foregroundStyle(DS.ink3).fixedSize(horizontal: false, vertical: true)
                }
            }

            BulletList(title: "注意", icon: "exclamationmark.triangle", items: analysis.risks, color: DS.warning)

            if !analysis.replySuggestions.isEmpty {
                ReplySuggestionsBlock(suggestions: analysis.replySuggestions, onFillReply: onFillReply)
            }
        }
        .textSelection(.enabled)
    }
}

struct ReplySuggestionsBlock: View {
    var suggestions: [ReplySuggestion]
    var onFillReply: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(title: onFillReply == nil ? "建议回复 · 点击复制" : "建议回复 · 点击填入", icon: "text.bubble")
            ForEach(suggestions, id: \.self) { s in
                if let onFillReply {
                    Button { onFillReply(s.text) } label: {
                        HStack(spacing: 8) {
                            Chip(text: s.style, color: DS.pick)
                            Text(s.text).font(DS.sub).foregroundStyle(DS.ink).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.down.left").font(.system(size: 10)).foregroundStyle(DS.ink4)
                        }
                        .padding(8)
                        .background(DS.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.edge, lineWidth: 0.75))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    MUCopyRow(tag: s.style, text: s.text)
                }
            }
        }
    }
}
