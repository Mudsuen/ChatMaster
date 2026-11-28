import AppKit
import LensCore
import MudsUI
import SwiftUI

enum Theme {
    /// AI / interactive accent (Bencho "pick").
    static let accent = DS.pick
    static let cardRadius = DS.radius
    /// Balanced ink for session/chat names (avoids pure `#FFFFFF` glare on dark surfaces).
    static let chatTitle = Color.mu(0x1E1F22, 0xD2D6DC)

    /// -1 … 1 -> red … ink … green
    static func valence(_ v: Double?) -> Color { MUTokens.valence(v) }

    static func urgency(_ u: String) -> Color {
        switch u {
        case "高": return DS.error
        case "中": return DS.warning
        default: return DS.ink4
        }
    }

    static func chatIcon(_ kind: ChatKind) -> String {
        switch kind {
        case .group: return "person.3.fill"
        case .official: return "megaphone.fill"
        case .system: return "gearshape.fill"
        case .person: return "person.fill"
        }
    }
}

struct SentimentDot: View {
    var value: Double?
    var body: some View {
        Circle().fill(Theme.valence(value)).frame(width: 6, height: 6).help(Sentiment.label(value))
    }
}

struct AvatarView: View {
    @EnvironmentObject var model: AppModel
    var username: String
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let img = model.avatar(username) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    DS.surface3
                    Text(String(model.displayName(username).prefix(1)))
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(DS.ink3)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(DS.edge, lineWidth: 0.5))
    }
}

enum DateFmt {
    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d"
        return f
    }()

    private static let yearMonthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yy/M/d"
        return f
    }()

    /// Compact single-line date formatter for list rows (never wraps like `"11月25日 11:35"`).
    static func compactList(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return Fmt.time.string(from: date) }
        if cal.isDateInYesterday(date) { return "昨天" }
        if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            return monthDay.string(from: date)
        }
        return yearMonthDay.string(from: date)
    }
}

/// Copies text and marks the change as ours so the clipboard bubble ignores it.
func copyText(_ text: String) {
    MUClipboard.copy(text)
}
