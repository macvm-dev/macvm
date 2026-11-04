public import Foundation
import MacVMModel

/// 从微软下载 Windows 11 ARM64 安装 ISO，缓存在 `DownloadCache.root` 下的 windows 目录。
///
/// 微软不公开直链：要像它的下载页那样先建会话、跑一遍页面里的指纹脚本，接口才肯按语言给出有效期一天的链接。
/// 请求都带浏览器的 User-Agent，接口不认其他客户端。微软不提供 ISO 的校验和，下载只核对字节数。
public enum WindowsISO {
    struct Release: Equatable {
        /// 如 `Windows 11 ARM 64 26H2 26300.9457`。
        let name: String
        /// 微软对语言的称呼，如 `Chinese (Simplified)`。
        let language: String
        let url: URL
        var fileName: String { url.lastPathComponent }
    }

    public static var cacheRoot: URL {
        DownloadCache.root.appending(path: "windows", directoryHint: .isDirectory)
    }

    /// 返回微软当前提供的、语言按 `languages` 挑选的 ISO，不在缓存里时先下载；下完后删掉缓存里其他的 ISO。
    /// 问不到微软时（离线、被拒）退而用缓存里最新的一份，缓存里也没有才报错。
    public static func iso(preferring languages: [String] = Locale.preferredLanguages, showProgress: Bool) async throws -> URL {
        // 只取一次：下载期间设置里的目录可能被改，中间文件得留在同一处。
        let root = cacheRoot
        let release: Release
        do { release = try await latestRelease(preferring: languages) } catch {
            guard !(error is CancellationError), let cached = cachedISOs(in: root).first else { throw error }
            return cached
        }
        let iso = root.appending(path: release.fileName)
        return try await Download.cached(iso, from: release.url, via: iso.appendingPathExtension("part"), showProgress: showProgress) { partial in
            try FileManager.default.moveItem(at: partial, to: iso)
            removeStaleISOs(keeping: release.fileName, in: root)
        }
    }

    /// 缓存里下完的 ISO，新的在前。
    static func cachedISOs(in root: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return items.filter { $0.pathExtension == "iso" }.sorted { modified($0) > modified($1) }
    }

    /// 删掉 `root` 里除 `current` 外下完的 ISO 与没下完的残留，`current` 的 `.part` 与锁文件不动。
    static func removeStaleISOs(keeping current: String, in root: URL) {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for item in items where !item.lastPathComponent.hasPrefix(current) && !item.lastPathComponent.hasSuffix(".lock") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - 微软下载页的接口

    static let pageURL = URL(string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!
    /// 页面读不出时用的产品版本号。
    static let fallbackProductEdition = "3816"
    /// 下载页嵌入的指纹脚本实例号与接口的 profile，是页面脚本里的常量。
    static let fingerprintInstance = "560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175"
    static let connectorProfile = "606624d44113"
    static let tagsOrganization = "y6jn8c31"

    /// 按下载页脚本的顺序请求：读产品版本号、跑指纹脚本、查各语言的 SKU，再取所选语言的下载链接。
    static func latestRelease(preferring languages: [String]) async throws -> Release {
        let client = Client()
        let page = (try? await client.text(pageURL)) ?? ""
        let edition = productEdition(inPage: page) ?? fallbackProductEdition
        let session = UUID().uuidString.lowercased()

        let script = try await client.text(URL(string: "https://ov-df.microsoft.com/mdt.js?instanceId=\(fingerprintInstance)&PageId=si&session_id=\(session)")!)
        if let beacon = fingerprintBeacon(inScript: script, now: .now) { _ = try? await client.data(beacon) }
        _ = try? await client.data(URL(string: "https://vlscppe.microsoft.com/tags?org_id=\(tagsOrganization)&session_id=\(session)")!)

        let skus = try await client.json(connector("getskuinformationbyproductedition",
                                                   ["ProductEditionId": edition, "SKU": "undefined"], session: session))
        try throwIfRefused(skus)
        let offered = (skus["Skus"] as? [[String: Any]] ?? []).compactMap { sku -> (id: String, language: String)? in
            guard let id = sku["Id"] as? String, let language = sku["Language"] as? String else { return nil }
            return (id, language)
        }
        guard let language = skuLanguage(for: languages, offered: offered.map(\.language)),
              let sku = offered.first(where: { $0.language == language })
        else { throw unexpectedAnswer }

        let links = try await client.json(connector("GetProductDownloadLinksBySku",
                                                    ["productEditionId": "undefined", "SKU": sku.id], session: session),
                                          referer: WindowsInstaller.downloadPage)
        try throwIfRefused(links)
        guard let release = release(inLinks: links, language: language) else { throw unexpectedAnswer }
        return release
    }

    static func connector(_ method: String, _ parameters: [String: String], session: String) -> URL {
        var components = URLComponents(string: "https://www.microsoft.com/software-download-connector/api/\(method)")!
        components.queryItems = [URLQueryItem(name: "profile", value: connectorProfile)]
            + parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "friendlyFileName", value: "undefined"), URLQueryItem(name: "Locale", value: "en-US"),
               URLQueryItem(name: "sessionID", value: session)]
        return components.url!
    }

    /// 页面下拉框里第一个 Arm64 选项的值。
    static func productEdition(inPage page: String) -> String? {
        page.firstMatch(of: /<option value="(\d+)">[^<]*Arm64[^<]*</).map { String($0.1) }
    }

    /// 指纹脚本让浏览器回访的地址，带上它算的 `rticks` 与当前毫秒时间。
    static func fingerprintBeacon(inScript script: String, now: Date) -> URL? {
        guard let address = script.firstMatch(of: /url:"([^"]+)"/).map({ String($0.1) }),
              let ticks = script.firstMatch(of: /rticks="\+(\d+)/).map({ String($0.1) })
        else { return nil }
        return URL(string: "\(address)&mdt=\(Int64(now.timeIntervalSince1970 * 1000))&rticks=\(ticks)")
    }

    /// 链接接口返回的第一个下载项。`Uri` 里的 `&` 被转义成了 `&amp;`。
    /// 文件名直接用作缓存路径：`lastPathComponent` 会解出 `%2F`，含 `/` 或以 `.` 开头的不认。
    static func release(inLinks links: [String: Any], language: String) -> Release? {
        guard let option = (links["ProductDownloadOptions"] as? [[String: Any]])?.first,
              let uri = option["Uri"] as? String,
              let url = URL(string: uri.replacingOccurrences(of: "&amp;", with: "&")), url.pathExtension.lowercased() == "iso",
              !url.lastPathComponent.contains("/"), !url.lastPathComponent.hasPrefix(".")
        else { return nil }
        return Release(name: option["ProductDisplayName"] as? String ?? "Windows 11", language: language, url: url)
    }

    private static func throwIfRefused(_ answer: [String: Any]) throws {
        let errors = (answer["Errors"] as? [[String: Any]])
            ?? ((answer["ValidationContainer"] as? [String: Any])?["Errors"] as? [[String: Any]]) ?? []
        guard let first = errors.first else { return }
        let reason = (first["Value"] as? String) ?? (first["Key"] as? String) ?? "未说明原因"
        throw MacVMError.io("微软拒绝了 Windows 下载请求（\(reason)），开着 VPN 或代理时常见。\(manualHint)")
    }

    private static var unexpectedAnswer: MacVMError {
        .io("没能从微软的下载接口取到 Windows 下载链接。\(manualHint)")
    }

    private static var manualHint: String {
        "可在浏览器打开 \(WindowsInstaller.downloadPage.absoluteString) 手动下载 ISO。"
    }

    // MARK: - 语言

    /// 语言标签前缀与微软对该语言的称呼；带地区或文字的前缀排在只有语言的前面。
    static let languageNames: [(tag: String, name: String)] = [
        ("zh-Hans", "Chinese (Simplified)"), ("zh-Hant", "Chinese (Traditional)"), ("zh-CN", "Chinese (Simplified)"),
        ("zh-SG", "Chinese (Simplified)"), ("zh-TW", "Chinese (Traditional)"), ("zh-HK", "Chinese (Traditional)"),
        ("zh-MO", "Chinese (Traditional)"), ("zh", "Chinese (Simplified)"),
        ("en-US", "English"), ("en", "English (United Kingdom)"), ("pt-BR", "Brazilian Portuguese"), ("pt", "Portuguese"),
        ("fr-CA", "French Canadian"), ("fr", "French"), ("es-MX", "Spanish (Mexico)"), ("es", "Spanish"),
        ("sr-Latn", "Serbian Latin"), ("sr", "Serbian Latin"), ("nb", "Norwegian"), ("no", "Norwegian"),
        ("ar", "Arabic"), ("bg", "Bulgarian"), ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"),
        ("et", "Estonian"), ("fi", "Finnish"), ("de", "German"), ("el", "Greek"), ("he", "Hebrew"), ("hu", "Hungarian"),
        ("it", "Italian"), ("ja", "Japanese"), ("ko", "Korean"), ("lv", "Latvian"), ("lt", "Lithuanian"), ("pl", "Polish"),
        ("ro", "Romanian"), ("ru", "Russian"), ("sk", "Slovak"), ("sl", "Slovenian"), ("sv", "Swedish"), ("th", "Thai"),
        ("tr", "Turkish"), ("uk", "Ukrainian"),
    ]

    /// `preferred` 里第一个微软提供的语言；都没有时用 English，再没有就用第一个。
    static func skuLanguage(for preferred: [String], offered: [String]) -> String? {
        for tag in preferred {
            for (prefix, name) in languageNames where tag == prefix || tag.hasPrefix(prefix + "-") {
                if offered.contains(name) { return name }
            }
        }
        return offered.contains("English") ? "English" : offered.first
    }

    // MARK: - HTTP

    private struct Client {
        let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpAdditionalHeaders = [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                "Accept-Language": "en-US,en;q=0.9",
            ]
            configuration.timeoutIntervalForRequest = 30
            return URLSession(configuration: configuration)
        }()

        func data(_ url: URL, referer: URL? = nil) async throws -> Data {
            var request = URLRequest(url: url)
            if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
            let (data, response): (Data, URLResponse)
            do { (data, response) = try await session.data(for: request) } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                throw MacVMError.io("连不上微软的下载服务器（\(url.host() ?? "")）：\(error.localizedDescription)")
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw MacVMError.io("微软的下载服务器返回 HTTP \(http.statusCode)（\(url.host() ?? "")）。\(WindowsISO.manualHint)")
            }
            return data
        }

        func text(_ url: URL) async throws -> String {
            String(decoding: try await data(url), as: UTF8.self)
        }

        func json(_ url: URL, referer: URL? = nil) async throws -> [String: Any] {
            let data = try await data(url, referer: referer)
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw WindowsISO.unexpectedAnswer
            }
            return object
        }
    }
}
