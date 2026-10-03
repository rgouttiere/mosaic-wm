import Foundation

/// Unread counts live in window titles — "Inbox (16,257) - …", "(2) Slack", "* general" — and that
/// is the only place a window manager can read them from without talking to the app. Pure, so the
/// titles that matter are three lines in a self-test.
enum UnreadBadge {
    /// nil = nothing unread that we can see; 0 = unread without a number (a leading `*`/`•`);
    /// n > 0 = the number. Only a parenthesised group made of digits and thousand separators
    /// counts — "(Channel)" or "(3 participants)" is not a badge.
    // ICU syntax (\x{…}) for the narrow / non-breaking spaces French locales use as thousands
    // separators — NOT Swift's \u{…}, which NSRegularExpression rejects and `try!` turns into a
    // crash at launch (2026-10-03: a respawn loop under the agent until the pattern was fixed).
    private static let count = try? NSRegularExpression(pattern: #"\(\s*(\d[\d.,\x{202F}\x{00A0} ]*)\s*\)"#)

    static func parse(_ title: String) -> Int? {
        let range = NSRange(title.startIndex..., in: title)
        if let count, let m = count.firstMatch(in: title, range: range), let r = Range(m.range(at: 1), in: title) {
            let digits = title[r].filter(\.isNumber)
            if let n = Int(digits), n > 0 { return n }
        }
        let head = title.drop(while: { $0 == " " })
        if let first = head.first, "*•●".contains(first) { return 0 }
        return nil
    }
}
