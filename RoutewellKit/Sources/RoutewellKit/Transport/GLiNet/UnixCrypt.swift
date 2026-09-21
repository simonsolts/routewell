import CryptoKit
import Foundation

/// Unix `crypt(3)`-compatible password hashing: Poul-Henning Kamp's
/// md5-crypt (`$1$`) and Ulrich Drepper's sha256-crypt (`$5$`) / sha512-crypt
/// (`$6$`). Used only to reproduce the hash GL.iNet's router expects during
/// login; never used to store Routewell's own secrets.
public enum UnixCrypt {
    private static let base64Alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// Appends `n` base64 characters to `output`, least-significant 6 bits first.
    private static func appendBase64(_ value: UInt32, count: Int, to output: inout [Character]) {
        var value = value
        for _ in 0..<count {
            output.append(base64Alphabet[Int(value & 0x3f)])
            value >>= 6
        }
    }

    // MARK: md5-crypt

    public static func md5Crypt(password: String, salt: String) -> String {
        let magic = "$1$"
        let pw = Array(password.utf8)
        let slt = Array(String(salt.prefix(8)).utf8)

        var ctx1 = Insecure.MD5()
        ctx1.update(data: Data(pw))
        ctx1.update(data: Data(slt))
        ctx1.update(data: Data(pw))
        let finalB = Array(Data(ctx1.finalize()))

        var ctx = Insecure.MD5()
        ctx.update(data: Data(pw))
        ctx.update(data: Data(magic.utf8))
        ctx.update(data: Data(slt))

        var pl = pw.count
        while pl > 0 {
            let take = min(pl, 16)
            ctx.update(data: Data(finalB[0..<take]))
            pl -= 16
        }

        var i = pw.count
        while i != 0 {
            if i & 1 != 0 {
                ctx.update(data: Data([0]))
            } else if let first = pw.first {
                ctx.update(data: Data([first]))
            }
            i >>= 1
        }

        var final = Array(Data(ctx.finalize()))

        for round in 0..<1000 {
            var ctx1 = Insecure.MD5()
            if round & 1 != 0 {
                ctx1.update(data: Data(pw))
            } else {
                ctx1.update(data: Data(final))
            }
            if round % 3 != 0 {
                ctx1.update(data: Data(slt))
            }
            if round % 7 != 0 {
                ctx1.update(data: Data(pw))
            }
            if round & 1 != 0 {
                ctx1.update(data: Data(final))
            } else {
                ctx1.update(data: Data(pw))
            }
            final = Array(Data(ctx1.finalize()))
        }

        var chars: [Character] = []
        appendBase64(UInt32(final[0]) << 16 | UInt32(final[6]) << 8 | UInt32(final[12]), count: 4, to: &chars)
        appendBase64(UInt32(final[1]) << 16 | UInt32(final[7]) << 8 | UInt32(final[13]), count: 4, to: &chars)
        appendBase64(UInt32(final[2]) << 16 | UInt32(final[8]) << 8 | UInt32(final[14]), count: 4, to: &chars)
        appendBase64(UInt32(final[3]) << 16 | UInt32(final[9]) << 8 | UInt32(final[15]), count: 4, to: &chars)
        appendBase64(UInt32(final[4]) << 16 | UInt32(final[10]) << 8 | UInt32(final[5]), count: 4, to: &chars)
        appendBase64(UInt32(final[11]), count: 2, to: &chars)

        let saltString = String(decoding: slt, as: UTF8.self)
        return "\(magic)\(saltString)$\(String(chars))"
    }

    // MARK: sha256-crypt / sha512-crypt (Drepper)

    public static func sha256Crypt(password: String, salt: String, rounds: Int = 5000) -> String {
        shaCrypt(password: password, salt: salt, rounds: rounds, id: "5",
                 hash: { Array(Data(SHA256.hash(data: Data($0)))) },
                 permute: permuteSHA256, digestByteCount: 32)
    }

    public static func sha512Crypt(password: String, salt: String, rounds: Int = 5000) -> String {
        shaCrypt(password: password, salt: salt, rounds: rounds, id: "6",
                 hash: { Array(Data(SHA512.hash(data: Data($0)))) },
                 permute: permuteSHA512, digestByteCount: 64)
    }

    private static func shaCrypt(
        password: String,
        salt: String,
        rounds: Int,
        id: String,
        hash: ([UInt8]) -> [UInt8],
        permute: ([UInt8]) -> [Character],
        digestByteCount: Int
    ) -> String {
        let pw = Array(password.utf8)
        let slt = Array(String(salt.prefix(16)).utf8)
        let clampedRounds = min(max(rounds, 1000), 999_999_999)

        // Digest B: password + salt + password.
        let digestB = hash(pw + slt + pw)

        // Digest A: password + salt + (digest B repeated/truncated to password length).
        var aInput = pw + slt
        var remaining = pw.count
        while remaining > 0 {
            let take = min(remaining, digestByteCount)
            aInput += digestB.prefix(take)
            remaining -= take
        }
        var bitCount = pw.count
        while bitCount > 0 {
            if bitCount & 1 != 0 {
                aInput += digestB
            } else {
                aInput += pw
            }
            bitCount >>= 1
        }
        var digestA = hash(aInput)

        // Digest DP: password repeated `password.count` times, then stretched to password length.
        var dpInput: [UInt8] = []
        for _ in 0..<pw.count { dpInput += pw }
        let digestDP = hash(dpInput)
        let sequenceP = repeated(digestDP, to: pw.count)

        // Digest DS: salt repeated (16 + digestA[0]) times, then stretched to salt length.
        var dsInput: [UInt8] = []
        for _ in 0..<(16 + Int(digestA[0])) { dsInput += slt }
        let digestDS = hash(dsInput)
        let sequenceS = repeated(digestDS, to: slt.count)

        for round in 0..<clampedRounds {
            var input: [UInt8] = []
            if round % 2 != 0 {
                input += sequenceP
            } else {
                input += digestA
            }
            if round % 3 != 0 {
                input += sequenceS
            }
            if round % 7 != 0 {
                input += sequenceP
            }
            if round % 2 != 0 {
                input += digestA
            } else {
                input += sequenceP
            }
            digestA = hash(input)
        }

        let encoded = String(permute(digestA))
        let saltString = String(decoding: slt, as: UTF8.self)
        if clampedRounds == 5000 {
            return "$\(id)$\(saltString)$\(encoded)"
        }
        return "$\(id)$rounds=\(clampedRounds)$\(saltString)$\(encoded)"
    }

    private static func repeated(_ digest: [UInt8], to length: Int) -> [UInt8] {
        guard length > 0 else { return [] }
        var result: [UInt8] = []
        result.reserveCapacity(length)
        while result.count < length {
            let take = min(digest.count, length - result.count)
            result += digest.prefix(take)
        }
        return result
    }

    private static func permuteSHA256(_ digest: [UInt8]) -> [Character] {
        var chars: [Character] = []
        let groups: [(Int, Int, Int, Int)] = [
            (0, 10, 20, 4), (21, 1, 11, 4), (12, 22, 2, 4), (3, 13, 23, 4), (24, 4, 14, 4),
            (15, 25, 5, 4), (6, 16, 26, 4), (27, 7, 17, 4), (18, 28, 8, 4), (9, 19, 29, 4),
        ]
        for (b2, b1, b0, n) in groups {
            appendBase64(UInt32(digest[b2]) << 16 | UInt32(digest[b1]) << 8 | UInt32(digest[b0]), count: n, to: &chars)
        }
        appendBase64(UInt32(digest[31]) << 8 | UInt32(digest[30]), count: 3, to: &chars)
        return chars
    }

    private static func permuteSHA512(_ digest: [UInt8]) -> [Character] {
        var chars: [Character] = []
        let groups: [(Int, Int, Int, Int)] = [
            (0, 21, 42, 4), (22, 43, 1, 4), (44, 2, 23, 4), (3, 24, 45, 4), (25, 46, 4, 4),
            (47, 5, 26, 4), (6, 27, 48, 4), (28, 49, 7, 4), (50, 8, 29, 4), (9, 30, 51, 4),
            (31, 52, 10, 4), (53, 11, 32, 4), (12, 33, 54, 4), (34, 55, 13, 4), (56, 14, 35, 4),
            (15, 36, 57, 4), (37, 58, 16, 4), (59, 17, 38, 4), (18, 39, 60, 4), (40, 61, 19, 4),
            (62, 20, 41, 4),
        ]
        for (b2, b1, b0, n) in groups {
            appendBase64(UInt32(digest[b2]) << 16 | UInt32(digest[b1]) << 8 | UInt32(digest[b0]), count: n, to: &chars)
        }
        appendBase64(UInt32(digest[63]), count: 2, to: &chars)
        return chars
    }
}
