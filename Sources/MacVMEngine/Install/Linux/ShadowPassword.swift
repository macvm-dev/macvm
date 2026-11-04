import CryptoKit
import Foundation

/// glibc `crypt(3)` 的 SHA-512 口令散列（`$6$`），写进 `/etc/shadow` 的格式。
/// 主机的 LibreSSL `openssl passwd` 不支持这种格式，只能自己算。
enum ShadowPassword {
    /// 用默认的 5000 轮，散列串里不带 `rounds=`。
    static func sha512Crypt(_ password: String, salt: String = randomSalt()) -> String {
        let p = [UInt8](password.utf8), s = [UInt8](salt.utf8.prefix(16))
        func digest(_ parts: [UInt8]...) -> [UInt8] {
            var h = SHA512()
            for part in parts { h.update(data: part) }
            return [UInt8](h.finalize())
        }
        func repeated(_ bytes: [UInt8], toLength n: Int) -> [UInt8] {
            bytes.isEmpty ? [] : (0..<n).map { bytes[$0 % bytes.count] }
        }

        let b = digest(p, s, p)
        var a = SHA512()
        a.update(data: p)
        a.update(data: s)
        a.update(data: repeated(b, toLength: p.count))
        var n = p.count
        while n > 0 {
            a.update(data: n & 1 == 1 ? b : p)
            n >>= 1
        }
        var c = [UInt8](a.finalize())

        let pBytes = repeated(digest(Array(Array(repeating: p, count: p.count).joined())), toLength: p.count)
        let sBytes = repeated(digest(Array(Array(repeating: s, count: 16 + Int(c[0])).joined())), toLength: s.count)
        for i in 0..<5000 {
            var h = SHA512()
            h.update(data: i & 1 == 1 ? pBytes : c)
            if i % 3 != 0 { h.update(data: sBytes) }
            if i % 7 != 0 { h.update(data: pBytes) }
            h.update(data: i & 1 == 1 ? c : pBytes)
            c = [UInt8](h.finalize())
        }

        let order: [(Int, Int, Int)] = [
            (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4), (47, 5, 26), (6, 27, 48),
            (28, 49, 7), (50, 8, 29), (9, 30, 51), (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13),
            (56, 14, 35), (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19), (62, 20, 41),
        ]
        var encoded = ""
        for (x, y, z) in order { encoded += base64(c[x], c[y], c[z], count: 4) }
        encoded += base64(0, 0, c[63], count: 2)
        return "$6$" + String(decoding: s, as: UTF8.self) + "$" + encoded
    }

    private static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// crypt 自己的 base64：低位在前，字母表与 RFC 4648 不同。
    private static func base64(_ b2: UInt8, _ b1: UInt8, _ b0: UInt8, count: Int) -> String {
        var w = UInt32(b2) << 16 | UInt32(b1) << 8 | UInt32(b0)
        var out = ""
        for _ in 0..<count {
            out.append(alphabet[Int(w & 0x3f)])
            w >>= 6
        }
        return out
    }

    static func randomSalt() -> String {
        String((0..<16).map { _ in alphabet.randomElement()! })
    }
}
