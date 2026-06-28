//
//  main.swift
//  clipy-realm-export
//
//  CLI entry point: read the original Clipy Realm history → ClipySi History Manager JSON,
//  text-only. Defaults to the standard release locations; override with flags. Then import the JSON
//  via the ClipySi app: History… → Import…
//
//  Usage:
//    clipy-realm-export [--realm <default.realm>] [--data-dir <dir>] [--output <file.json>]
//
//  Defaults:
//    --realm     ~/Library/Application Support/com.clipy-app.Clipy/default.realm
//    --data-dir  ~/Library/Application Support/Clipy
//    --output    stdout
//

import ClipyRealmExportKit
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("clipy-realm-export: \(message)\n".utf8))
    exit(code)
}

func printUsage() {
    let text = """
    clipy-realm-export — export original Clipy history to ClipySi JSON (text-only)

    USAGE:
      clipy-realm-export [--realm <path>] [--data-dir <path>] [--output <path>]

    OPTIONS:
      --realm <path>     Original default.realm (default: ~/Library/Application Support/com.clipy-app.Clipy/default.realm)
      --data-dir <path>  Per-clip .data directory (default: ~/Library/Application Support/Clipy)
      --output, -o <p>   Write JSON to this file (default: stdout)
      --help, -h         Show this help

    Then import the JSON in ClipySi: History… → Import…
    """
    print(text)
}

let home = FileManager.default.homeDirectoryForCurrentUser
var realmURL = home.appendingPathComponent("Library/Application Support/com.clipy-app.Clipy/default.realm")
var dataDir = home.appendingPathComponent("Library/Application Support/Clipy")
var outputURL: URL?

let args = Array(CommandLine.arguments.dropFirst())
var index = 0
func nextValue(_ flag: String) -> String {
    index += 1
    guard index < args.count else { fail("missing value for \(flag)", code: 2) }
    return args[index]
}
while index < args.count {
    switch args[index] {
    case "--realm": realmURL = URL(fileURLWithPath: nextValue("--realm"))
    case "--data-dir": dataDir = URL(fileURLWithPath: nextValue("--data-dir"))
    case "--output", "-o": outputURL = URL(fileURLWithPath: nextValue(args[index]))
    case "--help", "-h": printUsage(); exit(0)
    default: fail("unknown argument: \(args[index])", code: 2)
    }
    index += 1
}

guard FileManager.default.fileExists(atPath: realmURL.path) else {
    fail("realm not found at \(realmURL.path) — pass --realm <path>")
}

do {
    let options = HistoryExtractor.Options(realmURL: realmURL, dataDirectory: dataDir)
    let (data, summary) = try HistoryExtractor().export(options: options, now: Date())
    if let outputURL {
        try data.write(to: outputURL, options: .atomic)
        // The output is UNENCRYPTED plain text — restrict to the owner.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        FileHandle.standardError.write(Data("Wrote \(outputURL.path)\n".utf8))
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    FileHandle.standardError.write(
        Data("Exported \(summary.exported) text item(s); skipped \(summary.skipped) (non-text / missing / unreadable).\n".utf8))
} catch {
    fail("export failed: \(error.localizedDescription)")
}
