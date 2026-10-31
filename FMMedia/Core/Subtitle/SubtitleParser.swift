import Foundation

struct SubtitleCue: Identifiable, Hashable, Codable {
    var id: Int
    var start: Double
    var end: Double
    var text: String
    var italic: Bool = false
    var bold: Bool = false

    func contains(time: Double) -> Bool {
        time >= start && time <= end
    }
}

struct SubtitleParseResult {
    var cues: [SubtitleCue]
    var encoding: String.Encoding
    var format: String
}

/// SRT / ASS / SSA / VTT 字幕解析
enum SubtitleParser {
    static func parseFile(url: URL) -> SubtitleParseResult? {
        guard let decoded = TextDecoding.decodeFile(at: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let cues = parse(text: decoded.text, hintExtension: ext)
        guard !cues.isEmpty else { return nil }
        return SubtitleParseResult(cues: cues, encoding: decoded.encoding, format: formatName(for: ext, text: decoded.text))
    }

    static func parse(text: String, hintExtension: String = "") -> [SubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lower = normalized.lowercased()
        let ext = hintExtension.lowercased()

        var cues: [SubtitleCue]
        if ext == "ass" || ext == "ssa" || lower.contains("[events]") || lower.contains("dialogue:") {
            cues = parseASS(normalized)
        } else if ext == "vtt" || lower.contains("webvtt") {
            cues = parseTimeBased(normalized)
        } else {
            cues = parseTimeBased(normalized)
        }

        if cues.isEmpty {
            cues = parseASS(normalized)
        }

        cues.sort { $0.start < $1.start }
        for index in cues.indices {
            cues[index].id = index
        }
        return cues
    }

    // MARK: - SRT / VTT

    private static func parseTimeBased(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var start: Double?
        var end: Double?
        var buffer: [String] = []

        func flush() {
            if let startValue = start, let endValue = end, endValue > startValue {
                let rawText = buffer.joined(separator: "\n")
                var italic = false
                var bold = false
                if rawText.lowercased().contains("<i>") { italic = true }
                if rawText.lowercased().contains("<b>") { bold = true }
                let cleaned = stripHTML(rawText)
                if !cleaned.isEmpty {
                    cues.append(SubtitleCue(id: cues.count,
                                            start: startValue,
                                            end: endValue,
                                            text: cleaned,
                                            italic: italic,
                                            bold: bold))
                }
            }
            start = nil
            end = nil
            buffer.removeAll()
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmed
            if let arrow = rawLine.range(of: "-->") {
                flush()
                let left = String(rawLine[..<arrow.lowerBound])
                var right = String(rawLine[arrow.upperBound...]).trimmed
                if let space = right.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                    right = String(right[..<space])
                }
                start = parseTimecode(left)
                end = parseTimecode(right)
            } else if line.isEmpty {
                flush()
            } else if start != nil {
                buffer.append(rawLine)
            }
        }
        flush()
        return cues
    }

    // MARK: - ASS / SSA

    private static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var inEvents = false

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmed
            if line.hasPrefix("[") {
                inEvents = line.lowercased().hasPrefix("[events]")
                continue
            }
            guard inEvents else { continue }
            let lower = line.lowercased()
            guard lower.hasPrefix("dialogue:") else { continue }

            let content = String(line.dropFirst("dialogue:".count))
            let fields = content.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 10 else { continue }

            guard let start = parseTimecode(fields[1]), let end = parseTimecode(fields[2]) else { continue }
            let rawText = fields[9]

            var italic = false
            var bold = false
            if rawText.contains("\\i1") { italic = true }
            if rawText.contains("\\b1") { bold = true }

            var cleaned = stripASSOverrides(rawText)
            cleaned = cleaned
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
            cleaned = stripHTML(cleaned)

            guard !cleaned.isEmpty, end > start else { continue }
            cues.append(SubtitleCue(id: cues.count, start: start, end: end, text: cleaned, italic: italic, bold: bold))
        }
        return cues
    }

    private static func stripASSOverrides(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                result.append(character)
            }
        }
        return result
    }

    static func stripHTML(_ text: String) -> String {
        var result = ""
        var insideTag = false
        for character in text {
            if character == "<" {
                insideTag = true
            } else if character == ">" {
                insideTag = false
            } else if !insideTag {
                result.append(character)
            }
        }
        return result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmed
    }

    // MARK: - 时间码

    static func parseTimecode(_ raw: String) -> Double? {
        let cleaned = raw.trimmed
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: ";", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }

        let seconds = Double(parts[parts.count - 1].replacingOccurrences(of: " ", with: "")) ?? 0
        let minutes = Double(parts[parts.count - 2]) ?? 0
        let hours = parts.count >= 3 ? (Double(parts[parts.count - 3]) ?? 0) : 0
        let value = hours * 3600 + minutes * 60 + seconds
        return value.isFinite ? value : nil
    }

    static func formatName(for ext: String, text: String) -> String {
        switch ext {
        case "ass", "ssa": return "ASS"
        case "vtt": return "VTT"
        case "srt": return "SRT"
        default:
            let lower = text.lowercased()
            if lower.contains("[events]") { return "ASS" }
            if lower.contains("webvtt") { return "VTT" }
            return "SRT"
        }
    }
}
