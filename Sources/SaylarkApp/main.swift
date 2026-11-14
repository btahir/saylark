import AppKit
import Foundation
import SaylarkCore
import SaylarkUI

// The Saylark menu bar app. With no flags it runs the app on the live engine.
//   --fake-engine                              run the app on the fake engine (replayed voices, sample takes)
// Debug entry points live in the real app behind flags (no separate Dev app):
//   --pill-envelopes <manifest> [--out dir]   compute 120 Hz voice envelopes from your own eval clips
//   --pill-render <scenario|all> --out <dir>  render pill scenarios offscreen to MP4 + contact sheets
//   --pill-lab                                open the Pill Lab window
//   --ui-render [--out dir]                   render the Saylark window, Settings, onboarding and glyphs to PNG
// None of the debug flags install event taps, open the mic, touch the clipboard or ask for permissions.

let args = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let envelopeDir = URL(fileURLWithPath: value(after: "--envelopes") ?? "data/envelopes", relativeTo: repo)

if args.contains("--pill-envelopes") {
    guard let path = value(after: "--pill-envelopes"), !path.hasPrefix("--") else {
        FileHandle.standardError.write(Data("usage: --pill-envelopes <manifest.json> [--out dir]\n".utf8))
        exit(2)
    }
    let manifest = URL(fileURLWithPath: path, relativeTo: repo)
    let out = URL(fileURLWithPath: value(after: "--out") ?? "data/envelopes", relativeTo: repo)
    do {
        for line in try EnvelopeStore.extract(manifest: manifest, outDir: out) { print(line) }
    } catch {
        FileHandle.standardError.write(Data("envelopes failed: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

if let scenario = value(after: "--pill-render") {
    let out = URL(fileURLWithPath: value(after: "--out") ?? "launch/pill-lab", relativeTo: repo)
    let options = PillRenderOptions(
        stillsOnly: args.contains("--stills"),
        slowMotion: !args.contains("--no-slowmo"),
        accent: value(after: "--accent").flatMap(PillAccent.init(rawValue:)),
        visual: value(after: "--visual").flatMap(VoiceVisualKind.init(rawValue:))
    )
    let ok = MainActor.assumeIsolated {
        PillRenderCommand.run(scenario: scenario, outDir: out, envelopeDir: envelopeDir, options: options)
    }
    exit(ok ? 0 : 1)
}

if args.contains("--pill-lab") {
    MainActor.assumeIsolated {
        PillLab.run(envelopeDir: envelopeDir, selfTest: args.contains("--self-test"))
    }
    exit(0)
}

if args.contains("--ui-render") {
    let out = URL(fileURLWithPath: value(after: "--out") ?? "launch/m1", relativeTo: repo)
    let ok = MainActor.assumeIsolated { UIRenderCommand.run(outDir: out) }
    exit(ok ? 0 : 1)
}

MainActor.assumeIsolated {
    SaylarkMain.run(fake: args.contains("--fake-engine"), envelopeDir: envelopeDir)
}
