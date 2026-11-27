import Foundation

public enum ChatKind: String, Codable, Sendable {
    case person, group, official, system
}

public struct Contact: Hashable, Sendable {
    public var username: String
    public var remark: String
    public var nick: String
    public var alias: String
    public var kind: ChatKind
    public var flag: Int64
    public var chatRoomNotify: Int

    public init(username: String, remark: String, nick: String, alias: String, kind: ChatKind,
                flag: Int64 = 0, chatRoomNotify: Int = 1) {
        self.username = username
        self.remark = remark
        self.nick = nick
        self.alias = alias
        self.kind = kind
        self.flag = flag
        self.chatRoomNotify = chatRoomNotify
    }

    public var display: String {
        if !remark.isEmpty { return remark }
        if !nick.isEmpty { return nick }
        if !alias.isEmpty { return alias }
        return kind == .group ? "群聊" : username
    }

    /// Group folded into WeChat's `@placeholder_foldgroup` folder (bit 28 of `contact.flag`).
    public var isFolded: Bool { (flag & 0x1000_0000) != 0 }

    /// Muted (免打扰): folded chats, bit 9 (`0x200`) on any contact, or `chat_room_notify == 0` on groups.
    /// Note: 1-on-1 contacts commonly have `chat_room_notify == 0` even when unmuted, so only groups check it.
    public var isMuted: Bool { isFolded || (flag & 0x200) != 0 || (kind == .group && chatRoomNotify == 0) }

    /// Pinned (置顶) in WeChat's chat list (bit 11 of `contact.flag`).
    public var isPinned: Bool { (flag & 0x800) != 0 }

    public static func kind(of username: String) -> ChatKind {
        if username.hasSuffix("@chatroom") { return .group }
        if username.hasPrefix("gh_") { return .official }
        let system: Set<String> = ["filehelper", "weixin", "fmessage", "medianote", "floatbottle", "newsapp",
                                   "notifymessage", "qqmail", "tmessage", "qmessage", "qqsync", "brandsessionholder",
                                   "brandservicesessionholder", "notification_messages", "opencustomerservicemsg",
                                   "@placeholder_foldgroup"]
        if system.contains(username) || username.hasPrefix("@") { return .system }
        return .person
    }
}

public struct SessionInfo: Hashable, Sendable {
    public var username: String
    public var summary: String
    public var lastTimestamp: Int64
    public var unread: Int
    public var hidden: Bool
    /// Bumped by WeChat when the chat is opened (unread cleared) — used to follow chat switches.
    public var lastClearUnread: Int64 = 0
}

/// A message as stored in the Lens index.
public struct LensMessage: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var chat: String
    public var sender: String?
    public var isSelf: Bool
    public var ts: Int64
    public var baseType: Int
    public var subType: Int
    public var kind: String
    public var text: String
    public var quote: String?
    public var sentiment: Double?
    /// Set when WeChat recalled this message after WeChatLens had indexed the original.
    public var recalledAt: Int64? = nil
    public var recallNotice: String? = nil

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
    public var isTextual: Bool { baseType == 1 || (baseType == 49 && subType == 57) }
    public var isSystem: Bool { baseType == 10000 || baseType == 10002 }
    public var isRecalled: Bool { recalledAt != nil }
    public var recallDelay: Int64? { recalledAt.map { max(0, $0 - ts) } }

    public init(id: Int64, chat: String, sender: String?, isSelf: Bool, ts: Int64, baseType: Int, subType: Int,
                kind: String, text: String, quote: String?, sentiment: Double?) {
        self.id = id; self.chat = chat; self.sender = sender; self.isSelf = isSelf; self.ts = ts
        self.baseType = baseType; self.subType = subType; self.kind = kind; self.text = text
        self.quote = quote; self.sentiment = sentiment
    }
}

/// Chat list entry (index aggregate + session + contact).
public struct ChatSummary: Identifiable, Hashable, Sendable {
    public var id: String { username }
    public var username: String
    public var display: String
    public var kind: ChatKind
    public var lastTs: Int64
    public var count: Int
    public var unread: Int
    public var lastText: String
    public var isMuted: Bool
    public var isFolded: Bool
    public var isHidden: Bool
    public var isPinned: Bool

    public init(username: String, display: String, kind: ChatKind, lastTs: Int64, count: Int, unread: Int,
                lastText: String, isMuted: Bool = false, isFolded: Bool = false, isHidden: Bool = false,
                isPinned: Bool = false) {
        self.username = username
        self.display = display
        self.kind = kind
        self.lastTs = lastTs
        self.count = count
        self.unread = unread
        self.lastText = lastText
        self.isMuted = isMuted
        self.isFolded = isFolded
        self.isHidden = isHidden
        self.isPinned = isPinned
    }
}
