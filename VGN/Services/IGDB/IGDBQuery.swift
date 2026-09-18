import Foundation

/// A small, careful builder for Apicalypse — IGDB's query language sent as the raw
/// body of a `POST /v4/<endpoint>`. Each clause is optional; `build()` emits them in
/// the order IGDB expects and terminates every clause with `;`.
///
/// The one genuinely dangerous input is free-text search: a stray `"` would break out
/// of the `search "…"` string, so `search(_:)` escapes it (backslash-escaping `"` and
/// `\`). Everything else is composed from our own field lists and integer ids.
struct IGDBQuery {
    private var searchText: String?
    private var fieldList: [String] = []
    private var whereClause: String?
    private var sortClause: String?
    private var limitValue: Int?
    private var offsetValue: Int?

    init() {}

    func search(_ text: String) -> IGDBQuery {
        var copy = self
        copy.searchText = text
        return copy
    }

    func fields(_ fields: [String]) -> IGDBQuery {
        var copy = self
        copy.fieldList = fields
        return copy
    }

    func filter(_ clause: String) -> IGDBQuery {
        var copy = self
        copy.whereClause = clause
        return copy
    }

    func sort(_ clause: String) -> IGDBQuery {
        var copy = self
        copy.sortClause = clause
        return copy
    }

    func limit(_ value: Int) -> IGDBQuery {
        var copy = self
        copy.limitValue = value
        return copy
    }

    func offset(_ value: Int) -> IGDBQuery {
        var copy = self
        copy.offsetValue = value
        return copy
    }

    func build() -> String {
        var lines: [String] = []
        if let searchText {
            lines.append("search \"\(Self.escape(searchText))\";")
        }
        if !fieldList.isEmpty {
            lines.append("fields \(fieldList.joined(separator: ","));")
        }
        if let whereClause {
            lines.append("where \(whereClause);")
        }
        if let sortClause {
            lines.append("sort \(sortClause);")
        }
        if let limitValue {
            lines.append("limit \(limitValue);")
        }
        if let offsetValue {
            lines.append("offset \(offsetValue);")
        }
        return lines.joined(separator: " ")
    }

    /// Escape a search string so it is safe inside `search "…"`. Backslashes first,
    /// then double quotes; control characters (newlines) are collapsed to spaces.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 4)
        for ch in text {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n", "\r", "\t": out += " "
            default: out.append(ch)
            }
        }
        return out
    }

    /// Format a list of integer ids as an Apicalypse set literal, e.g. `(1,2,3)`.
    static func idSet(_ ids: [Int64]) -> String {
        "(" + ids.map(String.init).joined(separator: ",") + ")"
    }

    static func idSet(_ ids: [Int]) -> String {
        "(" + ids.map(String.init).joined(separator: ",") + ")"
    }
}
