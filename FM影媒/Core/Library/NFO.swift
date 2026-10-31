import Foundation

struct NFOPerson: Hashable {
    var name: String = ""
    var role: String = ""
    var thumb: String? = nil
}

/// .nfo（Kodi / Emby 兼容）影片信息
struct NFOData {
    var title: String = ""
    var originalTitle: String = ""
    var sortTitle: String = ""
    var plot: String = ""
    var outline: String = ""
    var tagline: String = ""
    var studio: String = ""
    var publisher: String = ""
    var mpaa: String = ""
    var year: Int? = nil
    var premiered: String = ""
    var runtimeMinutes: Int? = nil
    var rating: Double? = nil
    var genres: [String] = []
    var tags: [String] = []
    var directors: [String] = []
    var actors: [NFOPerson] = []
    var posterURL: String? = nil
    var fanartURL: String? = nil
    var uniqueID: String? = nil
    var trailer: String? = nil

    var hasContent: Bool {
        !title.isEmpty || !originalTitle.isEmpty || !plot.isEmpty || !outline.isEmpty
    }
}

/// 使用 XMLParser 解析 nfo，容错处理缺失字段
final class NFOParser: NSObject, XMLParserDelegate {
    private var data = NFOData()
    private var text = ""
    private var stack: [String] = []
    private var currentActor: NFOPerson?
    private var inActor = false
    private var actorField = ""
    private var ratingCount = 0
    private var ratingSum = 0.0

    static func parse(url: URL) -> NFOData? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        if let parsed = parse(data: raw), parsed.hasContent {
            return parsed
        }
        // NFO 可能是 GBK / BIG5 等编码，先解码成 UTF-8 再解析一次
        if let decoded = TextDecoding.decode(raw),
           let utf8 = decoded.text.data(using: .utf8),
           let parsed = parse(data: utf8),
           parsed.hasContent {
            return parsed
        }
        return parse(data: raw)
    }

    static func parse(data: Data) -> NFOData? {
        let parser = NFOParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        xml.shouldResolveExternalEntities = false
        guard xml.parse() else { return parser.data }
        return parser.data
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let tag = elementName.lowercased()
        stack.append(tag)
        text = ""
        if tag == "actor" {
            currentActor = NFOPerson()
            inActor = true
        }
        if inActor, let actor = currentActor, actor.name.isEmpty, tag == "name" {
            actorField = "name"
        }
        if tag == "thumb", stack.contains("fanart") {
            actorField = "fanartthumb"
        } else if tag == "thumb", stack.contains("actor") {
            actorField = "actorthumb"
        } else if tag == "thumb" {
            actorField = "posterthumb"
        }
        if tag == "uniqueid", let type = attributeDict["type"]?.lowercased(), type == "imdb" || type == "tmdb" {
            actorField = "uniqueid"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let tag = elementName.lowercased()
        let value = text.trimmed
        defer {
            text = ""
            if !stack.isEmpty { stack.removeLast() }
        }

        switch tag {
        case "title":
            if data.title.isEmpty { data.title = value }
        case "originaltitle":
            data.originalTitle = value
        case "sorttitle":
            data.sortTitle = value
        case "plot":
            if !value.isEmpty { data.plot = value }
        case "outline":
            data.outline = value
        case "tagline":
            data.tagline = value
        case "studio":
            if data.studio.isEmpty { data.studio = value }
        case "publisher":
            data.publisher = value
        case "mpaa":
            data.mpaa = value
        case "year":
            data.year = Int(value)
        case "premiered", "releasedate":
            data.premiered = value
        case "runtime":
            data.runtimeMinutes = Int(value)
        case "rating":
            if let rating = Double(value) { ratingSum += rating; ratingCount += 1 }
        case "votes":
            break
        case "genre":
            if !value.isEmpty { data.genres.append(value) }
        case "tag":
            if !value.isEmpty { data.tags.append(value) }
        case "director":
            if !value.isEmpty { data.directors.append(value) }
        case "name":
            if inActor, var actor = currentActor {
                actor.name = value
                currentActor = actor
            }
        case "role":
            if inActor, var actor = currentActor {
                actor.role = value
                currentActor = actor
            }
        case "thumb":
            switch actorField {
            case "fanartthumb": data.fanartURL = value
            case "actorthumb":
                if var actor = currentActor { actor.thumb = value; currentActor = actor }
            default: if data.posterURL == nil { data.posterURL = value }
            }
            actorField = ""
        case "uniqueid":
            if !value.isEmpty { data.uniqueID = value }
        case "trailer":
            data.trailer = value
        case "actor":
            if let actor = currentActor, !actor.name.isEmpty { data.actors.append(actor) }
            currentActor = nil
            inActor = false
        default:
            break
        }

        if tag == "rating", ratingCount > 0 {
            data.rating = ratingSum / Double(ratingCount)
        }
    }
}
