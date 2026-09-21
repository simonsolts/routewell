import Testing
@testable import RoutewellKit

// Vectors generated locally with `openssl passwd` (OpenSSL 3.6.4, no network)
// and cross-checked against PHP's `crypt()` (glibc-derived) for the rounds
// and salt-truncation cases openssl's CLI cannot express directly.

@Test func md5CryptMatchesOpenSSLPasswdVector() {
    // openssl passwd -1 -salt saltsalt password
    #expect(UnixCrypt.md5Crypt(password: "password", salt: "saltsalt") == "$1$saltsalt$qjXMvbEw8oaL.CzflDtaK/")
}

@Test func md5CryptMatchesSecondOpenSSLPasswdVector() {
    // openssl passwd -1 -salt 37784Ahz 'correct horse'
    #expect(UnixCrypt.md5Crypt(password: "correct horse", salt: "37784Ahz") == "$1$37784Ahz$A31O0f9qcaTa0YHB3ctJK.")
}

@Test func md5CryptTruncatesSaltToEightCharacters() {
    // openssl passwd -1 -salt saltsaltsaltsalt password (glibc truncates to the first 8 salt chars)
    #expect(UnixCrypt.md5Crypt(password: "password", salt: "saltsaltsaltsalt") == "$1$saltsalt$qjXMvbEw8oaL.CzflDtaK/")
}

@Test func md5CryptHandlesEmptyPassword() {
    // openssl passwd -1 -salt saltsalt '' (verified with PHP crypt() too)
    #expect(UnixCrypt.md5Crypt(password: "", salt: "saltsalt") == "$1$saltsalt$5Jhcit4zN9UlGiA0txPkO0")
}

@Test func sha256CryptMatchesDrepperPublishedVector() {
    // Drepper's published sha256-crypt test vector; also reproduced by
    // `openssl passwd -5 -salt saltstring 'Hello world!'`.
    #expect(UnixCrypt.sha256Crypt(password: "Hello world!", salt: "saltstring")
        == "$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5")
}

@Test func sha512CryptMatchesDrepperPublishedVector() {
    // Drepper's published sha512-crypt test vector; also reproduced by
    // `openssl passwd -6 -salt saltstring 'Hello world!'`.
    #expect(UnixCrypt.sha512Crypt(password: "Hello world!", salt: "saltstring")
        == "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1")
}

@Test func sha256CryptWithExplicitRoundsIncludesRoundsPrefixAndTruncatesSalt() {
    // Salt "saltstringsaltstring" (20 chars) truncates to 16 for sha-crypt;
    // verified with PHP's crypt(), which is glibc-derived and supports
    // `rounds=` where this build of openssl's CLI does not.
    #expect(UnixCrypt.sha256Crypt(password: "Hello world!", salt: "saltstringsaltstring", rounds: 10000)
        == "$5$rounds=10000$saltstringsaltst$3xv.VbSHBb41AL9AvLeujZkZRBAwqFMz2.opqey6IcA")
}

@Test func sha512CryptWithExplicitRoundsIncludesRoundsPrefixAndTruncatesSalt() {
    // Verified with PHP's crypt().
    #expect(UnixCrypt.sha512Crypt(password: "Hello world!", salt: "saltstringsaltstring", rounds: 10000)
        == "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v.")
}

@Test func sha256CryptOmitsRoundsPrefixWhenRoundsIsDefault() {
    let hash = UnixCrypt.sha256Crypt(password: "Hello world!", salt: "saltstring", rounds: 5000)
    #expect(!hash.contains("rounds="))
    #expect(hash == "$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5")
}

@Test func sha256CryptHandlesEmptyPassword() {
    // openssl passwd -5 -salt saltstring ''
    #expect(UnixCrypt.sha256Crypt(password: "", salt: "saltstring")
        == "$5$saltstring$FdNfA4gXqvCeO6iZs7G/.wwwoywYZqo0l1pwmfWaBA7")
}

@Test func sha256CryptWithSixteenCharacterSaltIsNotTruncated() {
    // 16 chars is exactly the sha-crypt max; verified with PHP's crypt().
    #expect(UnixCrypt.sha256Crypt(password: "Hello world!", salt: "1234567890ABCDEF")
        == "$5$1234567890ABCDEF$QALZkr4AFH099.KeKz0SQd.3xj0BTXSyA0QA2omdBj3")
}
