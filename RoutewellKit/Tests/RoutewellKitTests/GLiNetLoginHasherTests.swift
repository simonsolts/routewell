import Testing
@testable import RoutewellKit

@Test func loginHashMD5MatchesIndependentlyComputedDigest() throws {
    // crypt = openssl passwd -1 -salt 37784Ahz 'correct horse'
    //       = $1$37784Ahz$A31O0f9qcaTa0YHB3ctJK.
    // expected = echo -n "root:$1$37784Ahz$A31O0f9qcaTa0YHB3ctJK.:DhBsQ0VDGDiFrbWE0e0fmN5uW7Aql0Zq" | md5
    let challenge = GLiNetChallenge(alg: 1, salt: "37784Ahz", nonce: "DhBsQ0VDGDiFrbWE0e0fmN5uW7Aql0Zq", hashMethod: nil)
    let hash = try GLiNetLoginHasher.loginHash(username: "root", password: "correct horse", challenge: challenge)
    #expect(hash == "806ff4b7ca5b405f3989d4c7582004ab")
}

@Test func loginHashMD5ExplicitHashMethodMatchesDefault() throws {
    let challenge = GLiNetChallenge(alg: 1, salt: "37784Ahz", nonce: "DhBsQ0VDGDiFrbWE0e0fmN5uW7Aql0Zq", hashMethod: "md5")
    let hash = try GLiNetLoginHasher.loginHash(username: "root", password: "correct horse", challenge: challenge)
    #expect(hash == "806ff4b7ca5b405f3989d4c7582004ab")
}

@Test func loginHashSHA256MatchesIndependentlyComputedDigest() throws {
    // crypt = $1$37784Ahz$A31O0f9qcaTa0YHB3ctJK. (as above)
    // expected = echo -n "root:$1$37784Ahz$A31O0f9qcaTa0YHB3ctJK.:DhBsQ0VDGDiFrbWE0e0fmN5uW7Aql0Zq" | shasum -a 256
    let challenge = GLiNetChallenge(alg: 1, salt: "37784Ahz", nonce: "DhBsQ0VDGDiFrbWE0e0fmN5uW7Aql0Zq", hashMethod: "sha256")
    let hash = try GLiNetLoginHasher.loginHash(username: "root", password: "correct horse", challenge: challenge)
    #expect(hash == "3cab18de223f54b1a5530a125fe0e6da964e1afe7d38ba44ddea193c809bef66")
}

@Test func loginHashUnsupportedAlgorithmThrows() {
    let challenge = GLiNetChallenge(alg: 7, salt: "37784Ahz", nonce: "nonce", hashMethod: nil)
    #expect(throws: GLiNetRPCError.unsupportedAlgorithm(7)) {
        try GLiNetLoginHasher.loginHash(username: "root", password: "x", challenge: challenge)
    }
}

@Test func loginHashUnsupportedHashMethodThrows() {
    let challenge = GLiNetChallenge(alg: 1, salt: "37784Ahz", nonce: "nonce", hashMethod: "sha3")
    #expect(throws: GLiNetRPCError.unsupportedHashMethod("sha3")) {
        try GLiNetLoginHasher.loginHash(username: "root", password: "x", challenge: challenge)
    }
}

@Test func loginHashSHA512MatchesIndependentlyComputedDigest() throws {
    // crypt = $1$37784Ahz$A31O0f9qcaTa0YHB3ctJK. (as above)
    // expected = printf '%s' "root:$1$37784Ahz$A31O0f9qcaTa0YHB3ctJK.:DhBsQ0VDGDiFrbWE0e0fmN5uW7Aql0Zq" | shasum -a 512
    let challenge = GLiNetChallenge(alg: 1, salt: "37784Ahz", nonce: "DhBsQ0VDGDiFrbWE0e0fmN5uW7Aql0Zq", hashMethod: "sha512")
    let hash = try GLiNetLoginHasher.loginHash(username: "root", password: "correct horse", challenge: challenge)
    #expect(hash == "6d960e3f9ce10ba5c31e70c59b21094ca398b377ea7f6f9eaf51b0084c7172d33ec75d1a84480e581024236ea69be1cd570517230248d033d860106958513a39")
}

@Test func loginHashSaltIsTrimmedOfDollarSignsAndNewlines() throws {
    // Same crypt inputs as above, but the router-sent salt is wrapped the
    // way a raw crypt() salt field sometimes is; the sanitized salt must
    // still be "37784Ahz" for the hash to match.
    let wrapped = GLiNetChallenge(alg: 1, salt: "$37784Ahz$\r\n", nonce: "DhBsQ0VDGDiFrbWE0e0fmN5uW7Aql0Zq", hashMethod: nil)
    let plain = GLiNetChallenge(alg: 1, salt: "37784Ahz", nonce: "DhBsQ0VDGDiFrbWE0e0fmN5uW7Aql0Zq", hashMethod: nil)
    let wrappedHash = try GLiNetLoginHasher.loginHash(username: "root", password: "correct horse", challenge: wrapped)
    let plainHash = try GLiNetLoginHasher.loginHash(username: "root", password: "correct horse", challenge: plain)
    #expect(wrappedHash == plainHash)
    #expect(wrappedHash == "806ff4b7ca5b405f3989d4c7582004ab")
}

@Test func challengeInitAcceptsAlgAsNumericString() throws {
    let result = JSONValue.object([
        "alg": .string("1"),
        "salt": .string("37784Ahz"),
        "nonce": .string("nonce"),
    ])
    let challenge = try GLiNetChallenge(result: result)
    #expect(challenge.alg == 1)
    #expect(challenge.hashMethod == nil)
}

@Test func challengeInitAcceptsAlgAsInt() throws {
    let result = JSONValue.object([
        "alg": .number(5),
        "salt": .string("saltstring"),
        "nonce": .string("nonce"),
        "hash-method": .string("sha256"),
    ])
    let challenge = try GLiNetChallenge(result: result)
    #expect(challenge.alg == 5)
    #expect(challenge.hashMethod == "sha256")
}

@Test func challengeInitMissingFieldThrowsMalformedResponse() {
    let result = JSONValue.object(["alg": .number(1), "salt": .string("s")])
    #expect(throws: GLiNetRPCError.malformedResponse) {
        try GLiNetChallenge(result: result)
    }
}
