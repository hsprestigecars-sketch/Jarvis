import Foundation

/// Level 3 — permanently blocked capabilities.
///
/// These checks are code, not prompt text. They run on every tool request
/// regardless of what Claude, a web page, a file or the user says.
public enum BlockedPolicy {
    public enum Finding: Equatable, Sendable {
        case paymentCardNumber
        case bankAccountNumber
        case cryptoSecret
        case credential
        case authenticationCode
        case financialTransaction
        case financialDestination(String)

        public var explanation: String {
            switch self {
            case .paymentCardNumber:
                "It contains what looks like a payment card number. JARVIS never handles credit or debit cards."
            case .bankAccountNumber:
                "It contains what looks like a bank account number. JARVIS never accesses banking."
            case .cryptoSecret:
                "It contains what looks like a cryptocurrency private key or recovery phrase. JARVIS never handles wallets or keys."
            case .credential:
                "It contains a password or credential. JARVIS never handles passwords."
            case .authenticationCode:
                "It contains a one-time, verification or recovery code. JARVIS never handles authentication codes."
            case .financialTransaction:
                "It asks to move money or trade. JARVIS never makes transfers, payments or trades."
            case .financialDestination(let host):
                "It targets a banking, payment, brokerage or crypto service (\(host)). JARVIS never operates financial services."
            }
        }
    }

    // MARK: Tool names

    private static let blockedNameFragments = [
        "bank", "transfer_money", "wire", "payment", "pay_", "purchase_with", "credit_card", "debit_card",
        "card_number", "trade", "stock", "brokerage", "invest", "crypto", "wallet", "private_key", "seed",
        "password", "passcode", "otp", "2fa", "auth_code", "verification_code", "recovery_code", "keychain_read",
    ]

    public static func isBlockedToolName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return blockedNameFragments.contains { lower.contains($0) }
    }

    // MARK: Destinations

    /// Hosts and URL schemes of financial services. Matching is by host suffix
    /// or label so subdomains are covered.
    static let financialHostLabels: Set<String> = [
        "paypal", "venmo", "zelle", "cash", "cashapp", "wise", "revolut", "monzo", "chime", "stripe", "square",
        "coinbase", "binance", "kraken", "crypto", "metamask", "ledger", "trezor", "blockchain", "uniswap",
        "robinhood", "schwab", "fidelity", "etrade", "vanguard", "interactivebrokers", "ibkr", "webull", "trading212",
        "chase", "wellsfargo", "bankofamerica", "citi", "citibank", "capitalone", "usbank", "pnc", "hsbc", "barclays",
        "santander", "lloydsbank", "natwest", "americanexpress", "amex", "discover", "klarna", "afterpay", "affirm",
    ]

    static let financialURLSchemes: Set<String> = [
        "paypal", "venmo", "cashapp", "coinbase", "robinhood", "metamask", "trust", "bitcoin", "ethereum", "wise",
        "revolut", "chase", "bofa", "wellsfargo", "schwab", "fidelity", "zelle", "shoebox", "wallet", "bank",
    ]

    public static func financialDestination(in text: String) -> String? {
        for candidate in urlCandidates(in: text) {
            if let scheme = candidate.scheme?.lowercased(), financialURLSchemes.contains(scheme) {
                return scheme + "://"
            }
            guard let host = candidate.host?.lowercased() else { continue }
            let labels = host.split(separator: ".").map(String.init)
            if labels.contains(where: { $0.contains("bank") || financialHostLabels.contains($0) }) {
                return host
            }
        }
        return nil
    }

    private static func urlCandidates(in text: String) -> [URL] {
        let pattern = #"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'<>]+|\b(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}\b"#
        return matches(pattern, in: text).compactMap { match in
            URL(string: match.contains("://") ? match : "https://" + match)
        }
    }

    // MARK: Content

    /// Scans free text for blocked material.
    public static func scan(_ text: String) -> Finding? {
        if containsPaymentCard(text) { return .paymentCardNumber }
        if containsIBAN(text) || matchesAny(bankDetailPatterns, text) { return .bankAccountNumber }
        if matchesAny(cryptoPatterns, text) { return .cryptoSecret }
        if matchesAny(authCodePatterns, text) { return .authenticationCode }
        if matchesAny(credentialPatterns, text) { return .credential }
        if matchesAny(transactionPatterns, text) { return .financialTransaction }
        if let host = financialDestination(in: text) { return .financialDestination(host) }
        return nil
    }

    static let credentialPatterns = [
        #"(?i)\bmy\s+(\w+\s+){0,3}(password|passcode|passphrase|pin)\s+(is|=|:)\s*\S+"#,
        #"(?i)\b(password|passwd|passcode|passphrase|pwd|secret|api[_-]?key|access[_-]?token)\w*\s*[:=]\s*["'][^"'\s]{4,}["']"#,
        #"(?i)\b(password|passcode)\s+is\s+\S+"#,
        #"(?i)\b(get|show|read|retrieve|tell me|find|look up|send|share|copy|reveal)\b.{0,30}\b(my |the )?(saved |stored )?(password|passcode|passkey)s?\b"#,
    ]

    static let authCodePatterns = [
        #"(?i)\b(otp|2fa|mfa)\b\D{0,15}\d{4,8}\b"#,
        #"(?i)\b(one[- ]time|verification|security|authentication|auth|login|sign[- ]in|access|confirmation)\s+(pass)?code\D{0,15}\d{4,8}\b"#,
        #"(?i)\b(recovery|backup) codes?\b"#,
        #"(?i)\b(get|read|show|retrieve|find|forward|tell me|send)\b.{0,30}\b(otp|one[- ]time (pass)?code|2fa code|verification code|authentication code|auth code|login code)s?\b"#,
    ]

    static let cryptoPatterns = [
        #"(?i)\b(seed|recovery|mnemonic|secret) (phrase|words)\b"#,
        #"(?i)\bprivate keys?\b"#,
        #"\b[xtyz]prv[1-9A-HJ-NP-Za-km-z]{100,}\b"#,
        #"\b[5KL][1-9A-HJ-NP-Za-km-z]{50,51}\b"#,
        #"(?i)\b(wallet|private|eth|btc|crypto)\b[^\n]{0,20}\b(0x)?[0-9a-f]{64}\b"#,
    ]

    static let bankDetailPatterns = [
        #"(?i)\b(routing|account|acct|iban)\s*(number|no\.?|#)\s*[:=]?\s*\d[\d -]{5,}"#,
        #"(?i)\bsort code\s*[:=]?\s*\d{2}[ -]?\d{2}[ -]?\d{2}\b"#,
        #"\b(SWIFT|BIC)( code)?\s*[:=]?\s*[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?\b"#,
    ]

    static let transactionPatterns = [
        #"(?i)\b(bank|wire|ach|sepa|swift)\s+transfers?\b"#,
        #"(?i)\b(log ?in|sign ?in)\b.{0,20}\b(bank|banking|brokerage|wallet)\b"#,
    ]

    // MARK: Requests

    /// Imperative requests for a blocked capability ("transfer $50 to...",
    /// "buy 10 shares...", "what's my bank password"). JARVIS refuses these
    /// locally, before Claude is involved, and shows the PROTECTED state.
    /// Questions and research ("what is a good brokerage?") are not matched.
    public static func classifyRequest(_ utterance: String) -> Finding? {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if containsPaymentCard(text) { return .paymentCardNumber }
        if containsIBAN(text) || matchesAny(bankDetailPatterns, text) { return .bankAccountNumber }
        if matchesAny(requestTransactionPatterns, text) { return .financialTransaction }
        if matchesAny(requestCryptoPatterns, text) { return .cryptoSecret }
        if matchesAny(requestCodePatterns, text) { return .authenticationCode }
        if matchesAny(requestCredentialPatterns, text) { return .credential }
        return nil
    }

    private static let lead = #"(?i)^(hey\s+)?(jarvis[,.!]?\s+)?(please\s+|can you\s+|could you\s+|i want you to\s+)?"#

    static let requestTransactionPatterns = [
        lead + #"(transfer|wire|send|pay|move|withdraw|deposit)\b(?!.{0,40}\b(message|text|email|note|reminder|invite)\b).{0,40}([$€£¥]\s?\d|\d+(\.\d+)?\s?(usd|eur|gbp|dollars|euros|pounds|bucks|btc|eth|bitcoin|ether|sats)\b|\b(money|funds|bitcoin|crypto)\b)"#,
        lead + #"(buy|sell|short|trade|purchase|invest in)\b.{0,30}\b(shares?|stocks?|options contracts?|futures|etfs?|bitcoin|btc|ethereum|eth|crypto(currency)?|tokens?|coins?)\b"#,
        lead + #"(open|log ?into|sign ?into|access)\b.{0,20}\b(bank|banking|brokerage|trading|crypto|wallet|credit card|debit card)\b"#,
        lead + #"(check|show|tell me|what'?s|what is)\b.{0,15}\bmy\s+(bank|checking|savings|brokerage|card|wallet|crypto|portfolio)\b.{0,15}\b(balance|statement|transactions|holdings)\b"#,
    ]

    static let requestCryptoPatterns = [
        #"(?i)\bmy\b.{0,20}\b(seed|recovery|mnemonic) phrase\b"#,
        #"(?i)\bmy\b.{0,20}\bprivate keys?\b"#,
        lead + #"(send|transfer|move)\b.{0,30}\b(bitcoin|btc|eth|ethereum|crypto|tokens?|coins?|nft)\b"#,
    ]

    static let requestCodePatterns = [
        #"(?i)\b(get|read|show|retrieve|find|forward|tell me|what('?s| is)|copy)\b.{0,20}\b(my|the|that|latest|last|new)\s+(otp|one[- ]time (pass)?code|2fa code|verification code|authentication code|auth code|login code|security code|sign[- ]in code|recovery codes?|backup codes?)\b"#,
    ]

    static let requestCredentialPatterns = [
        #"(?i)\b(get|show|read|retrieve|tell me|find|look up|what('?s| is)|remember|save|store|copy)\b.{0,20}\bmy\b.{0,20}\b(password|passcode|passkey|login credentials)s?\b"#,
        #"(?i)\bmy\s+(\w+\s+){0,3}(password|passcode|pin)\s+(is|=|:)\s*\S+"#,
    ]

    // MARK: Card / IBAN validation

    static func containsPaymentCard(_ text: String) -> Bool {
        for candidate in matches(#"(?<![\d])(?:\d[ -]?){12,18}\d(?![\d])"#, in: text) {
            let digits = candidate.filter(\.isNumber)
            guard (13...19).contains(digits.count), luhn(digits) else { continue }
            // Card numbers start with known issuer prefixes (2-6).
            if let first = digits.first, "23456".contains(first) { return true }
        }
        return false
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, char) in digits.reversed().enumerated() {
            guard var value = char.wholeNumberValue else { return false }
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }

    static func containsIBAN(_ text: String) -> Bool {
        for candidate in matches(#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b"#, in: text) {
            let compact = candidate.replacingOccurrences(of: " ", with: "")
            guard (15...34).contains(compact.count) else { continue }
            let rearranged = compact.dropFirst(4) + compact.prefix(4)
            var remainder = 0
            var valid = true
            for char in rearranged {
                let chunk: String
                if let digit = char.wholeNumberValue {
                    chunk = String(digit)
                } else if let ascii = char.asciiValue, char.isUppercase {
                    chunk = String(Int(ascii) - 55)
                } else {
                    valid = false
                    break
                }
                for c in chunk { remainder = (remainder * 10 + c.wholeNumberValue!) % 97 }
            }
            if valid, remainder == 1 { return true }
        }
        return false
    }

    // MARK: Redaction

    /// Removes card numbers and key material from tool output before it is
    /// shown to Claude, so a file or web page cannot leak them into the model.
    public static func redact(_ text: String) -> String {
        var result = text
        for candidate in matches(#"(?<![\d])(?:\d[ -]?){12,18}\d(?![\d])"#, in: result) {
            let digits = candidate.filter(\.isNumber)
            if (13...19).contains(digits.count), luhn(digits) {
                result = result.replacingOccurrences(of: candidate, with: "[REDACTED CARD NUMBER]")
            }
        }
        for pattern in [#"\b[xtyz]prv[1-9A-HJ-NP-Za-km-z]{100,}\b"#, #"\b[5KL][1-9A-HJ-NP-Za-km-z]{50,51}\b"#] {
            for candidate in matches(pattern, in: result) {
                result = result.replacingOccurrences(of: candidate, with: "[REDACTED KEY MATERIAL]")
            }
        }
        return result
    }

    // MARK: Regex helpers

    static func matchesAny(_ patterns: [String], _ text: String) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
