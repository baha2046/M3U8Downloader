import Foundation

public struct ParsedCurlRequest {
    public let url: String
    public let headers: [String]
}

public enum CurlRequestParserError: LocalizedError {
    case empty
    case notCurl
    case missingValue(String)
    case unterminatedQuote
    case missingUrl
    case invalidUrl
    
    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste a cURL request first."
        case .notCurl:
            return "cURL request must start with curl."
        case .missingValue(let option):
            return "\(option) requires a value."
        case .unterminatedQuote:
            return "Could not parse cURL request: unmatched quote."
        case .missingUrl:
            return "cURL request did not include an HTTP(S) URL."
        case .invalidUrl:
            return "Extracted URL must start with http:// or https://."
        }
    }
}

public enum CurlRequestParser {
    public static func parse(_ curlRequest: String) throws -> ParsedCurlRequest {
        let normalized = curlRequest
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "$'", with: "'")
        guard !normalized.isEmpty else {
            throw CurlRequestParserError.empty
        }
        
        let tokens = try shellTokens(normalized)
        guard let firstToken = tokens.first else {
            throw CurlRequestParserError.empty
        }
        let executable = URL(fileURLWithPath: firstToken).lastPathComponent.lowercased()
        guard executable == "curl" || executable == "curl.exe" else {
            throw CurlRequestParserError.notCurl
        }
        
        var urls: [String] = []
        var headers: [String] = []
        var cookieValues: [String] = []
        var userAgent: String?
        var referer: String?
        var index = 1
        
        while index < tokens.count {
            let token = tokens[index]
            
            if let value = try optionValue(tokens: tokens, index: &index, token: token, longName: "--header", shortName: "-H") {
                if value.contains(":") {
                    headers.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                continue
            }
            
            if let value = try optionValue(tokens: tokens, index: &index, token: token, longName: "--cookie", shortName: "-b") {
                let stripped = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if stripped.contains("=") || stripped.contains(";") {
                    cookieValues.append(stripped)
                }
                continue
            }
            
            if let value = try optionValue(tokens: tokens, index: &index, token: token, longName: "--url", shortName: nil) {
                urls.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
                continue
            }
            
            if let value = try optionValue(tokens: tokens, index: &index, token: token, longName: "--user-agent", shortName: "-A") {
                userAgent = value.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            
            if let value = try optionValue(tokens: tokens, index: &index, token: token, longName: "--referer", shortName: "-e") {
                referer = value.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            
            if token.hasPrefix("http://") || token.hasPrefix("https://") {
                urls.append(token)
                index += 1
                continue
            }
            
            if optionsWithValues.contains(token) {
                index += 2
            } else if shortOptionsWithValues.contains(token) {
                index += 2
            } else if shortOptionsWithValues.contains(where: { token.hasPrefix($0) && token != $0 }) {
                index += 1
            } else {
                index += 1
            }
        }
        
        if let userAgent, !headers.containsHeader(named: "user-agent") {
            headers.append("User-Agent: \(userAgent)")
        }
        if let referer, !headers.containsHeader(named: "referer") {
            headers.append("Referer: \(referer)")
        }
        if !cookieValues.isEmpty, !headers.containsHeader(named: "cookie") {
            headers.append("Cookie: \(cookieValues.joined(separator: "; "))")
        }
        
        guard let selectedUrl = urls.first(where: { $0.localizedCaseInsensitiveContains(".m3u8") }) ?? urls.first else {
            throw CurlRequestParserError.missingUrl
        }
        guard selectedUrl.hasPrefix("http://") || selectedUrl.hasPrefix("https://") else {
            throw CurlRequestParserError.invalidUrl
        }
        
        return ParsedCurlRequest(url: selectedUrl, headers: headers)
    }
    
    private static func optionValue(
        tokens: [String],
        index: inout Int,
        token: String,
        longName: String,
        shortName: String?
    ) throws -> String? {
        if token == longName || token == shortName {
            guard index + 1 < tokens.count else {
                throw CurlRequestParserError.missingValue(token)
            }
            index += 2
            return tokens[index - 1]
        }
        
        let longPrefix = "\(longName)="
        if token.hasPrefix(longPrefix) {
            index += 1
            return String(token.dropFirst(longPrefix.count))
        }
        
        if let shortName, token.hasPrefix(shortName), token != shortName {
            index += 1
            return String(token.dropFirst(shortName.count))
        }
        
        return nil
    }
    
    private static func shellTokens(_ command: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var iterator = command.makeIterator()
        
        while let character = iterator.next() {
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if activeQuote == "\"", character == "\\", let next = iterator.next() {
                    current.append(next)
                } else {
                    current.append(character)
                }
                continue
            }
            
            if character == "'" || character == "\"" {
                quote = character
            } else if character == "\\", let next = iterator.next() {
                current.append(next)
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        
        if quote != nil {
            throw CurlRequestParserError.unterminatedQuote
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
    
    private static let shortOptionsWithValues: Set<String> = [
        "-A", "-b", "-c", "-d", "-e", "-F", "-H", "-K", "-m", "-o", "-Q", "-r", "-T", "-u", "-x", "-X", "-Y", "-z"
    ]
    
    private static let optionsWithValues: Set<String> = [
        "--abstract-unix-socket", "--aws-sigv4", "--cacert", "--capath", "--cert", "--cert-type",
        "--ciphers", "--connect-timeout", "--connect-to", "--continue-at", "--data", "--data-ascii",
        "--data-binary", "--data-raw", "--data-urlencode", "--dns-interface", "--dns-ipv4-addr",
        "--dns-ipv6-addr", "--dns-servers", "--doh-url", "--dump-header", "--engine", "--form",
        "--form-string", "--ftp-account", "--ftp-alternative-to-user", "--hostpubmd5", "--hostpubsha256",
        "--interface", "--key", "--key-type", "--krb", "--limit-rate", "--local-port", "--login-options",
        "--mail-auth", "--mail-from", "--mail-rcpt", "--max-filesize", "--max-redirs", "--netrc-file",
        "--oauth2-bearer", "--output", "--pass", "--pinnedpubkey", "--proto", "--proto-default",
        "--proto-redir", "--proxy", "--proxy-cacert", "--proxy-capath", "--proxy-cert", "--proxy-cert-type",
        "--proxy-ciphers", "--proxy-header", "--proxy-key", "--proxy-key-type", "--proxy-pass",
        "--proxy-service-name", "--proxy-tls13-ciphers", "--proxy-tlsauthtype", "--proxy-tlspassword",
        "--proxy-tlsuser", "--proxy-user", "--pubkey", "--quote", "--range", "--request", "--request-target",
        "--resolve", "--retry", "--retry-delay", "--retry-max-time", "--service-name", "--socks4",
        "--socks4a", "--socks5", "--socks5-gssapi-service", "--socks5-hostname", "--speed-limit",
        "--speed-time", "--stderr", "--telnet-option", "--tftp-blksize", "--tls13-ciphers",
        "--tlspassword", "--tlsuser", "--unix-socket", "--upload-file", "--user"
    ]
}

private extension Array where Element == String {
    func containsHeader(named name: String) -> Bool {
        contains { header in
            header.split(separator: ":", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == name
        }
    }
}
