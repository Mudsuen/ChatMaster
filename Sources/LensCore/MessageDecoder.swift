import Foundation

/// Raw row of a WeChat `Msg_<md5>` table.
public struct RawMessage: Sendable {
    public var localID: Int64
    public var serverID: Int64
    public var localType: Int64
    public var senderUsername: String?
    public var createTime: Int64
    public var content: Data?
    public var contentText: String?
    public var compression: Int64
}

public struct DecodedMessage: Sendable, Equatable {
    public var sender: String?
    public var baseType: Int
    public var subType: Int
    public var kind: String
    public var text: String
    public var quote: String?
    /// WeChat rewrites a recalled message in place into a `revokemsg` system message.
    public var isRevoke = false
}

public enum MessageDecoder {
    public static func decode(_ raw: RawMessage, chat: String) -> DecodedMessage {
        let base = Int(raw.localType & 0xFFFF_FFFF)
        let sub = Int(raw.localType >> 32)
        var body = contentString(raw)
        var sender = raw.senderUsername

        // Group messages from others carry a "wxid_xxx:\n" prefix.
        if chat.hasSuffix("@chatroom"), let r = body.range(of: ":\n"), body.distance(from: body.startIndex, to: r.lowerBound) <= 64 {
            let head = String(body[body.startIndex..<r.lowerBound])
            if !head.isEmpty, head.allSatisfy({ $0.isLetter || $0.isNumber || "_-@.".contains($0) }), !head.contains(" ") {
                body = String(body[r.upperBound...])
                if sender == nil || sender == chat || sender?.isEmpty == true { sender = head }
            }
        }

        var kind = typeLabel(base: base, sub: sub)
        var text = body
        var quote: String?

        switch base {
        case 1:
            // Service accounts embed mini-program anchors in plain text.
            if body.contains("</a>") { text = stripTags(body) }
        case 3: text = "[图片]"
        case 34: text = "[语音]"
        case 43: text = "[视频]"
        case 47: text = "[表情]"
        case 48:
            let label = attr("poiname", in: body) ?? attr("label", in: body) ?? ""
            text = label.isEmpty ? "[位置]" : "[位置] \(label)"
        case 42:
            let nick = attr("nickname", in: body) ?? ""
            text = nick.isEmpty ? "[名片]" : "[名片] \(nick)"
        case 50: text = "[通话]"
        case 10000, 10002:
            if body.contains("revokemsg") {
                let notice = tag("content", in: body) ?? tag("replacemsg", in: body) ?? stripTags(body)
                return DecodedMessage(sender: sender, baseType: base, subType: sub, kind: "撤回",
                                      text: notice.trimmingCharacters(in: .whitespacesAndNewlines), quote: nil, isRevoke: true)
            }
            text = body.contains("<") ? stripTags(body) : body
            if text.isEmpty { text = "[系统消息]" }
        case 49:
            let title = tag("title", in: body) ?? ""
            let appType = Int(tag("type", in: body) ?? "") ?? sub
            let effective = sub != 0 ? sub : appType
            kind = typeLabel(base: 49, sub: effective)
            switch effective {
            case 57:
                text = title
                if let refer = section("refermsg", in: body) {
                    let name = tag("displayname", in: refer) ?? ""
                    var content = tag("content", in: refer) ?? ""
                    let rtype = Int(tag("type", in: refer) ?? "") ?? 1
                    if rtype != 1 { content = content.contains("<") ? "[\(typeLabel(base: rtype, sub: 0))]" : content }
                    content = content.replacingOccurrences(of: "\n", with: " ")
                    if content.count > 80 { content = String(content.prefix(80)) + "…" }
                    quote = name.isEmpty ? content : "\(name): \(content)"
                }
            case 5: text = "[链接] \(title)"
            case 6: text = "[文件] \(title)"
            case 33, 36, 62: text = "[小程序] \(title)"
            case 19: text = "[聊天记录] \(title)"
            case 2000:
                let fee = tag("feedesc", in: body) ?? ""
                text = "[转账] \(fee.isEmpty ? title : fee)"
            case 2001: text = "[红包] \(title)"
            case 51, 53:
                let nick = tag("nickname", in: body) ?? ""
                let desc = tag("desc", in: body) ?? title
                text = "[视频号] \(nick.isEmpty ? desc : nick + " " + desc)"
            case 4: text = "[音乐] \(title)"
            case 24: text = "[收藏] \(title)"
            default:
                text = title.isEmpty ? "[\(kind)]" : "[\(kind)] \(title)"
            }
        default:
            text = body.isEmpty || body.hasPrefix("<") ? "[\(kind)]" : body
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return DecodedMessage(sender: sender, baseType: base, subType: sub, kind: kind, text: text, quote: quote)
    }

    static func contentString(_ raw: RawMessage) -> String {
        if let data = raw.content {
            if Zstd.isCompressed(data), let d = Zstd.decompress(data) {
                return String(decoding: d, as: UTF8.self)
            }
            return String(decoding: data, as: UTF8.self)
        }
        return raw.contentText ?? ""
    }

    public static func typeLabel(base: Int, sub: Int) -> String {
        switch base {
        case 1: return "文本"
        case 3: return "图片"
        case 34: return "语音"
        case 43: return "视频"
        case 47: return "表情"
        case 48: return "位置"
        case 42: return "名片"
        case 50: return "通话"
        case 10000, 10002: return "系统"
        case 49:
            switch sub {
            case 57: return "引用"
            case 5: return "链接"
            case 6: return "文件"
            case 33, 36, 62: return "小程序"
            case 19: return "聊天记录"
            case 2000: return "转账"
            case 2001: return "红包"
            case 51, 53: return "视频号"
            case 4: return "音乐"
            case 24: return "收藏"
            default: return "应用消息"
            }
        default: return "其他"
        }
    }

    // MARK: - Minimal XML helpers (WeChat payloads are small and regular)

    static func tag(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>") ?? xml.range(of: "<\(name) ", options: []) else { return nil }
        var start = open.upperBound
        if xml[open].hasSuffix(" ") {
            guard let gt = xml[open.upperBound...].firstIndex(of: ">") else { return nil }
            if xml[xml.index(before: gt)] == "/" { return nil }
            start = xml.index(after: gt)
        }
        guard let close = xml.range(of: "</\(name)>", range: start..<xml.endIndex) else { return nil }
        var v = String(xml[start..<close.lowerBound])
        if v.hasPrefix("<![CDATA["), v.hasSuffix("]]>") {
            v = String(v.dropFirst(9).dropLast(3))
        }
        return unescape(v).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func section(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    static func attr(_ name: String, in xml: String) -> String? {
        guard let r = xml.range(of: " \(name)=\"") else { return nil }
        guard let end = xml[r.upperBound...].firstIndex(of: "\"") else { return nil }
        let v = unescape(String(xml[r.upperBound..<end]))
        return v.isEmpty ? nil : v
    }

    static func stripTags(_ s: String) -> String {
        var out = ""
        var inTag = false
        for c in s {
            if c == "<" { inTag = true; continue }
            if c == ">" { inTag = false; continue }
            if !inTag { out.append(c) }
        }
        return unescape(out).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#x0A;", with: "\n")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
