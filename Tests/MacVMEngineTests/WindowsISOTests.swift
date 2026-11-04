import Foundation
@testable import MacVMEngine
import Testing

struct WindowsISOTests {
    @Test func productEditionIsFirstArm64Option() {
        let page = #"<select><option value="" selected>Select</option><option value="3816">Windows 11 (multi-edition ISO for Arm64)</option></select>"#
        #expect(WindowsISO.productEdition(inPage: page) == "3816")
        #expect(WindowsISO.productEdition(inPage: "<html></html>") == nil)
    }

    @Test func fingerprintBeaconAddsTimeAndTicks() throws {
        let script = #"var a={url:"https://ov-df.microsoft.com/?session_id=abc&CustomerId=x"};b.rticks="+1793771603965;"#
        let beacon = try #require(WindowsISO.fingerprintBeacon(inScript: script, now: Date(timeIntervalSince1970: 2)))
        #expect(beacon.absoluteString == "https://ov-df.microsoft.com/?session_id=abc&CustomerId=x&mdt=2000&rticks=1793771603965")
        #expect(WindowsISO.fingerprintBeacon(inScript: "nothing", now: .now) == nil)
    }

    @Test func releaseUnescapesAmpersands() throws {
        let links: [String: Any] = ["ProductDownloadOptions": [[
            "Uri": "https://software.download.prss.microsoft.com/dbazure/Windows11_Client_arm64_zh-cn_26300_9457.iso?t=c3&amp;P1=17&amp;P4=fu%2f%3d%3d",
            "ProductDisplayName": "Windows 11 ARM 64 26H2 26300.9457",
        ]]]
        let release = try #require(WindowsISO.release(inLinks: links, language: "Chinese (Simplified)"))
        #expect(release.fileName == "Windows11_Client_arm64_zh-cn_26300_9457.iso")
        #expect(release.url.query == "t=c3&P1=17&P4=fu%2f%3d%3d")
        #expect(release.name == "Windows 11 ARM 64 26H2 26300.9457")
        #expect(WindowsISO.release(inLinks: ["ProductDownloadOptions": []], language: "English") == nil)
        let escaping: [String: Any] = ["ProductDownloadOptions": [["Uri": "https://example.com/dl/..%2F..%2Fevil.iso"]]]
        #expect(WindowsISO.release(inLinks: escaping, language: "English") == nil)
    }

    @Test func skuLanguageFollowsPreferredLanguages() {
        let offered = ["Arabic", "Chinese (Simplified)", "Chinese (Traditional)", "English", "English (United Kingdom)", "German", "Portuguese",
                       "Brazilian Portuguese"]
        #expect(WindowsISO.skuLanguage(for: ["zh-Hans-CN", "en-CN"], offered: offered) == "Chinese (Simplified)")
        #expect(WindowsISO.skuLanguage(for: ["zh-Hant-TW"], offered: offered) == "Chinese (Traditional)")
        #expect(WindowsISO.skuLanguage(for: ["pt-BR"], offered: offered) == "Brazilian Portuguese")
        #expect(WindowsISO.skuLanguage(for: ["de-DE"], offered: offered) == "German")
        #expect(WindowsISO.skuLanguage(for: ["en-US"], offered: offered) == "English")
        #expect(WindowsISO.skuLanguage(for: ["en-GB"], offered: offered) == "English (United Kingdom)")
        #expect(WindowsISO.skuLanguage(for: ["ja-JP"], offered: offered) == "English")
        #expect(WindowsISO.skuLanguage(for: ["ja-JP"], offered: ["Arabic"]) == "Arabic")
    }

    @Test func removeStaleISOsKeepsCurrentDownloadAndLocks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "macvm-winiso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = "Windows11_Client_arm64_zh-cn_26300_9457.iso"
        let names = [current, current + ".part.seg-0", current + ".part.segments", current + ".part.lock",
                     "Windows11_Client_arm64_zh-cn_26200_1000.iso", "Windows11_Client_arm64_en-us_26300_9457.iso.part",
                     "Windows11_Client_arm64_en-us_26300_9457.iso.part.lock"]
        for name in names { FileManager.default.createFile(atPath: root.appending(path: name).path, contents: nil) }
        WindowsISO.removeStaleISOs(keeping: current, in: root)
        let left = try Set(FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(left == [current, current + ".part.seg-0", current + ".part.segments", current + ".part.lock",
                         "Windows11_Client_arm64_en-us_26300_9457.iso.part.lock"])
    }
}
