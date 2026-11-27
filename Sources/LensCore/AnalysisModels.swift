import Foundation

// MARK: - Result models (decoding is tolerant: missing fields fall back to defaults)

extension KeyedDecodingContainer {
    func v<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

public struct ReplySuggestion: Codable, Hashable, Sendable {
    public var style: String
    public var text: String
}

public struct MessageAnalysis: Codable, Hashable, Sendable {
    public var emotion = "中性"
    public var secondaryEmotions: [String] = []
    public var emoji = "😐"
    public var valence = 0.0
    public var intensity = 1
    public var intent = "其他"
    public var intentDetail = ""
    public var subtext = ""
    public var toneTags: [String] = []
    public var needsReply = false
    public var urgency = "低"
    public var risks: [String] = []
    public var replySuggestions: [ReplySuggestion] = []
    public var confidence = 0.5
    public var evidence = ""

    enum CodingKeys: String, CodingKey {
        case emotion, secondaryEmotions, emoji, valence, intensity, intent, intentDetail, subtext, toneTags
        case needsReply, urgency, risks, replySuggestions, confidence, evidence
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emotion = c.v(.emotion, emotion); secondaryEmotions = c.v(.secondaryEmotions, [])
        emoji = c.v(.emoji, emoji); valence = c.v(.valence, 0); intensity = c.v(.intensity, 1)
        intent = c.v(.intent, intent); intentDetail = c.v(.intentDetail, ""); subtext = c.v(.subtext, "")
        toneTags = c.v(.toneTags, []); needsReply = c.v(.needsReply, false); urgency = c.v(.urgency, "低")
        risks = c.v(.risks, []); replySuggestions = c.v(.replySuggestions, []); confidence = c.v(.confidence, 0.5)
        evidence = c.v(.evidence, "")
    }

    public static let intents = ["提问", "请求帮助", "邀约", "分享", "告知", "抱怨", "求安慰", "试探", "拒绝", "同意",
                                 "道歉", "感谢", "催促", "调侃", "客套", "表达关心", "表达不满", "结束话题", "其他"]

    public static var schema: [String: Any] {
        S.obj([
            "emotion": S.str("主情绪，2-4 个字，如 开心、期待、委屈、不满、焦虑、平静、疲惫、讽刺"),
            "secondaryEmotions": S.arr(S.str("次要情绪")),
            "emoji": S.str("最贴切的一个 emoji"),
            "valence": S.num("情绪效价 -1(非常负面) 到 1(非常正面)"),
            "intensity": S.int("情绪强度 1-5"),
            "intent": S.str("意图类别", options: intents),
            "intentDetail": S.str("具体意图，一句话"),
            "subtext": S.str("潜台词/言外之意；没有就说明为字面意思"),
            "toneTags": S.arr(S.str("语气标签，如 反话、客套、敷衍、玩笑、认真、试探、撒娇、正式")),
            "needsReply": S.bool("我是否需要回复"),
            "urgency": S.str("回复紧急度", options: ["低", "中", "高"]),
            "risks": S.arr(S.str("需要注意的风险或雷区，可为空")),
            "replySuggestions": S.arr(S.obj(["style": S.str("风格，如 真诚、轻松、简短、委婉"),
                                             "text": S.str("可直接发送的回复")])),
            "confidence": S.num("置信度 0-1"),
            "evidence": S.str("判断依据，引用原文关键词，1-2 句"),
        ])
    }
}

public struct ConversationAnalysis: Codable, Hashable, Sendable {
    public var summary = ""
    public var overallMood = ""
    public var moodTrend = ""
    public var myState = ""
    public var theirState = ""
    public var topics: [String] = []
    public var keyPoints: [String] = []
    public var myTodos: [String] = []
    public var theirTodos: [String] = []
    public var openQuestions: [String] = []
    public var risks: [String] = []
    public var suggestedNextStep = ""
    public var replySuggestions: [ReplySuggestion] = []

    enum CodingKeys: String, CodingKey {
        case summary, overallMood, moodTrend, myState, theirState, topics, keyPoints, myTodos, theirTodos
        case openQuestions, risks, suggestedNextStep, replySuggestions
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = c.v(.summary, ""); overallMood = c.v(.overallMood, ""); moodTrend = c.v(.moodTrend, "")
        myState = c.v(.myState, ""); theirState = c.v(.theirState, ""); topics = c.v(.topics, [])
        keyPoints = c.v(.keyPoints, []); myTodos = c.v(.myTodos, []); theirTodos = c.v(.theirTodos, [])
        openQuestions = c.v(.openQuestions, []); risks = c.v(.risks, [])
        suggestedNextStep = c.v(.suggestedNextStep, ""); replySuggestions = c.v(.replySuggestions, [])
    }

    public static var schema: [String: Any] {
        S.obj([
            "summary": S.str("对话摘要，3-5 句"),
            "overallMood": S.str("整体氛围，如 轻松愉快、紧张、冷淡、温馨"),
            "moodTrend": S.str("情绪走向，如 由紧张转缓和"),
            "myState": S.str("我的状态/态度"),
            "theirState": S.str("对方（或群内主要发言者）的状态/态度"),
            "topics": S.arr(S.str("话题")),
            "keyPoints": S.arr(S.str("关键信息：时间、地点、金额、决定")),
            "myTodos": S.arr(S.str("我答应或需要去做的事")),
            "theirTodos": S.arr(S.str("对方答应或需要做的事")),
            "openQuestions": S.arr(S.str("还没回答/没解决的问题")),
            "risks": S.arr(S.str("潜在矛盾或需要注意的点")),
            "suggestedNextStep": S.str("我下一步该怎么做"),
            "replySuggestions": S.arr(S.obj(["style": S.str("风格"), "text": S.str("可直接发送的回复")])),
        ])
    }
}

public struct RelationshipReport: Codable, Hashable, Sendable {
    public var summary = ""
    public var closeness = 3
    public var closenessLabel = ""
    public var dynamics = ""
    public var theirStyle = ""
    public var myStyle = ""
    public var recurringTopics: [String] = []
    public var strengths: [String] = []
    public var frictions: [String] = []
    public var suggestions: [String] = []

    enum CodingKeys: String, CodingKey {
        case summary, closeness, closenessLabel, dynamics, theirStyle, myStyle, recurringTopics, strengths, frictions, suggestions
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = c.v(.summary, ""); closeness = c.v(.closeness, 3); closenessLabel = c.v(.closenessLabel, "")
        dynamics = c.v(.dynamics, ""); theirStyle = c.v(.theirStyle, ""); myStyle = c.v(.myStyle, "")
        recurringTopics = c.v(.recurringTopics, []); strengths = c.v(.strengths, []); frictions = c.v(.frictions, [])
        suggestions = c.v(.suggestions, [])
    }

    public static var schema: [String: Any] {
        S.obj([
            "summary": S.str("关系概述，3-4 句"),
            "closeness": S.int("亲密度 1-5"),
            "closenessLabel": S.str("关系标签，如 挚友、暧昧、工作伙伴、家人、点头之交"),
            "dynamics": S.str("互动模式：谁更主动、节奏、权力关系"),
            "theirStyle": S.str("对方的沟通风格"),
            "myStyle": S.str("我的沟通风格"),
            "recurringTopics": S.arr(S.str("常聊话题")),
            "strengths": S.arr(S.str("关系中好的地方")),
            "frictions": S.arr(S.str("摩擦点或隐患")),
            "suggestions": S.arr(S.str("改善或维护关系的具体建议")),
        ])
    }
}

public struct BriefItem: Codable, Hashable, Sendable {
    public var chat: String
    public var summary: String
    public var importance: String
}

public struct BriefNeed: Codable, Hashable, Sendable {
    public var chat: String
    public var reason: String
}

public struct DailyBriefing: Codable, Hashable, Sendable {
    public var headline = ""
    public var highlights: [BriefItem] = []
    public var needReply: [BriefNeed] = []
    public var myPromises: [String] = []
    public var moodAlerts: [String] = []
    public var suggestions: [String] = []

    enum CodingKeys: String, CodingKey { case headline, highlights, needReply, myPromises, moodAlerts, suggestions }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = c.v(.headline, ""); highlights = c.v(.highlights, []); needReply = c.v(.needReply, [])
        myPromises = c.v(.myPromises, []); moodAlerts = c.v(.moodAlerts, []); suggestions = c.v(.suggestions, [])
    }

    public static var schema: [String: Any] {
        S.obj([
            "headline": S.str("一句话总结今天的聊天"),
            "highlights": S.arr(S.obj(["chat": S.str("会话名"), "summary": S.str("要点"),
                                       "importance": S.str("重要度", options: ["高", "中", "低"])])),
            "needReply": S.arr(S.obj(["chat": S.str("会话名"), "reason": S.str("为什么需要我回复")])),
            "myPromises": S.arr(S.str("我答应别人的事（含对象和时间）")),
            "moodAlerts": S.arr(S.str("情绪异常提醒，如 某人似乎不开心")),
            "suggestions": S.arr(S.str("明天的行动建议")),
        ])
    }
}

// MARK: - JSON Schema helpers

enum S {
    static func str(_ d: String, options: [String]? = nil) -> [String: Any] {
        var o: [String: Any] = ["type": "string", "description": d]
        if let options { o["enum"] = options }
        return o
    }
    static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    static func arr(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
    static func obj(_ props: [String: [String: Any]]) -> [String: Any] {
        ["type": "object", "properties": props, "required": props.keys.sorted()]
    }

    static func json(_ schema: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }
}
