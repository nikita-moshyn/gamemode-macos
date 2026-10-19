//
//  verify_update.swift
//  GameMode
//
//  Created by Nikita Moshyn on 12/10/2026.
//  Copyright © 2026 Nikita Moshyn. All rights reserved.
//

import CryptoKit
import Foundation

guard CommandLine.arguments.count == 5 else {
    fputs("Usage: verify_update.swift archive signature public-key length\n", stderr)
    exit(1)
}

do {
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let signature = Data(base64Encoded: CommandLine.arguments[2]),
          let publicKeyData = Data(base64Encoded: CommandLine.arguments[3]),
          let expectedLength = Int(CommandLine.arguments[4]), expectedLength == archive.count else {
        throw NSError(domain: "GameMode.Release", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid signature metadata or archive length."])
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    guard publicKey.isValidSignature(signature, for: archive) else {
        throw NSError(domain: "GameMode.Release", code: 2, userInfo: [NSLocalizedDescriptionKey: "Sparkle signature does not match the archive and the app's SUPublicEDKey."])
    }
    print("Sparkle signature and archive length verified against the app's public key.")
} catch {
    fputs("Release verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
