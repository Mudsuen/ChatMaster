import Foundation

/// Fast, deterministic, local sentiment estimate for Chinese chat text (-1 … 1).
/// Used for trends and colour chips at scale; deep analysis goes through the LLM.
public enum Sentiment {
    private static let positive: [String: Double] = [
        "哈哈": 0.6, "嘻嘻": 0.6, "嘿嘿": 0.4, "开心": 0.8, "高兴": 0.8, "快乐": 0.8, "谢谢": 0.6, "感谢": 0.7,
        "多谢": 0.6, "太好了": 0.9, "好棒": 0.8, "真棒": 0.8, "厉害": 0.6, "喜欢": 0.7, "爱你": 0.9, "期待": 0.6,
        "恭喜": 0.8, "牛": 0.5, "好耶": 0.8, "么么": 0.7, "爱了": 0.7, "不错": 0.5, "可以呀": 0.4, "好呀": 0.5,
        "好的呀": 0.5, "辛苦了": 0.4, "棒": 0.5, "赞": 0.5, "放心": 0.3, "顺利": 0.6, "幸福": 0.8, "感动": 0.6,
        "满意": 0.6, "完美": 0.8, "妙": 0.4, "支持": 0.4, "加油": 0.5, "哇": 0.3, "嗯嗯": 0.2, "好滴": 0.4,
        "[微笑]": 0.3, "[呲牙]": 0.6, "[偷笑]": 0.5, "[愉快]": 0.7, "[憨笑]": 0.5, "[强]": 0.6, "[玫瑰]": 0.6,
        "[爱心]": 0.7, "[抱拳]": 0.4, "[庆祝]": 0.7, "[耶]": 0.6, "[哈哈]": 0.6, "[色]": 0.6, "[嘿哈]": 0.5,
        "[奸笑]": 0.2, "[机智]": 0.4, "[好的]": 0.4, "[OK]": 0.3, "[鼓掌]": 0.6, "[拥抱]": 0.6, "[亲亲]": 0.7,
        "😄": 0.6, "😂": 0.5, "🤣": 0.6, "😊": 0.6, "😍": 0.8, "🥰": 0.8, "👍": 0.5, "🎉": 0.7, "❤️": 0.7, "😁": 0.6,
        "🙏": 0.3, "💪": 0.4, "😘": 0.7,
    ]
    private static let negative: [String: Double] = [
        "烦": 0.6, "累": 0.4, "难过": 0.8, "伤心": 0.8, "生气": 0.8, "气死": 0.9, "讨厌": 0.7, "无语": 0.6,
        "崩溃": 0.9, "郁闷": 0.7, "失望": 0.8, "委屈": 0.8, "算了": 0.5, "呵呵": 0.5, "滚": 0.9, "垃圾": 0.7,
        "不想": 0.3, "唉": 0.5, "哎": 0.3, "糟糕": 0.7, "完蛋": 0.7, "焦虑": 0.7, "担心": 0.5, "害怕": 0.6,
        "对不起": 0.3, "抱歉": 0.2, "不开心": 0.8, "难受": 0.7, "心累": 0.8, "头疼": 0.6, "不行": 0.3,
        "不用管我": 0.8, "随便": 0.4, "行吧": 0.4, "麻烦": 0.4, "恶心": 0.8, "过分": 0.7, "受不了": 0.8,
        "后悔": 0.6, "可惜": 0.5, "痛苦": 0.9, "绝望": 0.9, "吵架": 0.7, "分手": 0.8, "骗": 0.6, "冷漠": 0.7,
        "敷衍": 0.7, "离谱": 0.5, "坑": 0.4, "急": 0.3, "催": 0.3, "失眠": 0.5, "生病": 0.5, "疼": 0.5,
        "[流泪]": 0.7, "[大哭]": 0.8, "[难过]": 0.7, "[发怒]": 0.8, "[撇嘴]": 0.5, "[抓狂]": 0.8, "[衰]": 0.6,
        "[叹气]": 0.5, "[裂开]": 0.6, "[白眼]": 0.6, "[委屈]": 0.7, "[快哭了]": 0.7, "[捂脸]": 0.2, "[汗]": 0.3,
        "[擦汗]": 0.3, "[皱眉]": 0.5, "[苦涩]": 0.5, "[生病]": 0.5, "[心碎]": 0.8, "[吐]": 0.6, "[鄙视]": 0.7,
        "😭": 0.7, "😢": 0.7, "😡": 0.9, "😤": 0.6, "💔": 0.8, "🙄": 0.5, "😞": 0.6, "😔": 0.6, "😩": 0.6, "😰": 0.6,
    ]
    private static let negators: [Character] = ["不", "没", "别", "未", "非"]
    private static let intensifiers = ["太", "非常", "超", "特别", "真的", "好", "巨", "超级", "十分", "很"]

    /// first character -> [(word, weight, isPositive)], longest words first
    private static let index: [Character: [(String, Double, Bool)]] = {
        var m: [Character: [(String, Double, Bool)]] = [:]
        for (w, v) in positive { if let c = w.first { m[c, default: []].append((w, v, true)) } }
        for (w, v) in negative { if let c = w.first { m[c, default: []].append((w, v, false)) } }
        for k in m.keys { m[k]!.sort { $0.0.count > $1.0.count } }
        return m
    }()

    public static func score(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let chars = Array(t)
        var sum = 0.0
        var hits = 0
        var i = 0
        while i < chars.count {
            guard let cands = index[chars[i]] else { i += 1; continue }
            var matched = 0
            for (word, w, pos) in cands {
                let wc = Array(word)
                guard i + wc.count <= chars.count, Array(chars[i..<(i + wc.count)]) == wc else { continue }
                hits += 1
                let neg = negated(chars, before: i)
                let b = boost(chars, before: i)
                if pos {
                    sum += neg ? -w * 0.7 : w * b
                } else {
                    // "不累" / "没生气" flip towards mildly positive
                    sum += neg && wc.first != "不" ? w * 0.3 : -w * b
                }
                matched = wc.count
                break
            }
            i += max(matched, 1)
        }
        // Short cold replies read as negative in Chinese chat.
        if ["哦", "嗯", "噢", "哦哦。", "嗯。", "哦。", "呵"].contains(t) { sum -= 0.3; hits += 1 }
        if hits == 0 { return 0 }
        let exclaim = chars.filter { $0 == "!" || $0 == "！" }.count
        var s = sum / Double(hits).squareRoot()
        if exclaim > 0 { s *= 1 + min(Double(exclaim), 3) * 0.1 }
        return max(-1, min(1, s))
    }

    private static func negated(_ c: [Character], before i: Int) -> Bool {
        for j in stride(from: i - 1, through: max(0, i - 2), by: -1) where negators.contains(c[j]) { return true }
        return false
    }

    private static func boost(_ c: [Character], before i: Int) -> Double {
        let prefix = String(c[max(0, i - 2)..<i])
        return intensifiers.contains(where: { prefix.hasSuffix($0) }) ? 1.3 : 1
    }

    public static func label(_ s: Double?) -> String {
        guard let s else { return "—" }
        switch s {
        case 0.35...: return "积极"
        case 0.1..<0.35: return "偏积极"
        case -0.1..<0.1: return "平静"
        case -0.35 ..< -0.1: return "偏消极"
        default: return "消极"
        }
    }
}
