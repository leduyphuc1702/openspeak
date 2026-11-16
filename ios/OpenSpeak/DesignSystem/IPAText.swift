import SwiftUI

/// Splits an IPA transcription into phone tokens so each phone can be styled.
/// Token order matches the `phones` array of the generated lesson content.
enum IPATokenizer {
    struct Token: Hashable {
        let text: String
        let isPhone: Bool
    }

    private static let multiCharacter = ["tʃ", "dʒ", "eɪ", "aɪ", "ɔɪ", "aʊ", "oʊ", "iː", "ɑː", "ɔː", "uː", "ɝː"]

    static func tokenize(_ ipa: String) -> [Token] {
        var tokens: [Token] = []
        var rest = Substring(ipa)
        while let first = rest.first {
            if first == "ˈ" || first == "ˌ" || first == " " {
                tokens.append(Token(text: String(first), isPhone: false))
                rest = rest.dropFirst()
            } else if let match = multiCharacter.first(where: { rest.hasPrefix($0) }) {
                tokens.append(Token(text: match, isPhone: true))
                rest = rest.dropFirst(match.count)
            } else {
                tokens.append(Token(text: String(first), isPhone: true))
                rest = rest.dropFirst()
            }
        }
        return tokens
    }

    /// The word's IPA with every occurrence of `phonemeID` highlighted.
    static func highlighted(_ entry: WordEntry, phonemeID: String, color: Color = Theme.primary) -> AttributedString {
        var result = AttributedString("/")
        var phoneIndex = 0
        for token in tokenize(entry.ipa) {
            var piece = AttributedString(token.text)
            if token.isPhone {
                if phoneIndex < entry.phones.count, entry.phones[phoneIndex] == phonemeID {
                    piece.foregroundColor = color
                    piece.font = .body.bold()
                }
                phoneIndex += 1
            }
            result += piece
        }
        result += AttributedString("/")
        return result
    }
}
