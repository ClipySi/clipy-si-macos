//
//  HistoryCipherTests.swift
//  ClipyTests
//

import CryptoKit
import Foundation
import Testing
@testable import Clipy

@Suite struct HistoryCipherTests {
    private let cipher = HistoryCipher(key: SymmetricKey(data: Data(repeating: 0x01, count: 32)))

    @Test func sealOpenRoundTrips() throws {
        let plaintext = Data("SECRET-PLAINTEXT-123".utf8)
        let sealed = try cipher.seal(plaintext)
        #expect(try cipher.open(sealed) == plaintext)
    }

    @Test func ciphertextDoesNotContainPlaintext() throws {
        let secret = Data("SECRET-PLAINTITLE-123".utf8)
        let sealed = try cipher.seal(secret)
        #expect(sealed.range(of: secret) == nil)
        #expect(sealed != secret)
    }

    @Test func openWithWrongKeyFails() throws {
        let sealed = try cipher.seal(Data("hi".utf8))
        let other = HistoryCipher(key: SymmetricKey(data: Data(repeating: 0x02, count: 32)))
        #expect(throws: (any Error).self) { try other.open(sealed) }
    }

    @Test func contentHashIsDeterministicAndKeyed() {
        let payload = Data("payload".utf8)
        let other = HistoryCipher(key: SymmetricKey(data: Data(repeating: 0x09, count: 32)))
        #expect(cipher.contentHash(payload) == cipher.contentHash(payload)) // deterministic
        #expect(cipher.contentHash(payload) != other.contentHash(payload))  // keyed
        #expect(cipher.contentHash(payload).count == 64)                    // SHA-256 → 32 bytes hex
    }

    @Test func sealUsesFreshNoncePerCall() throws {
        let payload = Data("same-input".utf8)
        #expect(try cipher.seal(payload) != cipher.seal(payload))
    }
}
