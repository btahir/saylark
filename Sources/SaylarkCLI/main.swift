import Foundation
import SaylarkCore

let usage = """
    saylark \(Saylark.version)

    usage:
      saylark transcribe <file.wav> [--json] [--windowed] [--v3]
      saylark bench <manifest.json> [--out FILE] [--pace realtime|simulated] [--chunk-ms 100]
                    [--min-pause 0.25] [--margin 0.1] [--min-window 10] [--max-window 14]
                    [--silence 0.5] [--guard 0.3] [--gap S] [--buckets a,b] [--limit N] [--vocab terms.txt] [--no-whole]
      saylark seed <wispr-import-dir> [--out-dir data/seed] [--sessions | --claude DIR]
                   [--eval-manifest M] [--no-asr] [--limit N]
      saylark seed-terms <data/seed> [--min-sightings 2] [--max 40] [--exclude-eval] [--aliases] --out terms.txt
      saylark simulate <file.wav> [--script hold|handsfree|tap|chord|esc|lostup|stop] [--warm] [--mic-delay 0.03]
                       [--unplug-after S] [--history DIR] [--keep] [--dict dictionary.txt]
                       [--send] [--no-field] [--no-clipboard] [--trigger fn|rightOption|rightCommand] [--no-paragraphs]
      saylark doctor [--pin <device uid>] [--mic-open N]   (--mic-open opens the real mic N times)
      saylark insert-test [--verbose]
      saylark dict list|path [--file FILE]
      saylark dict add <term> [--as alias,alias] [--file FILE]
      saylark dict remove <term> [--file FILE]
      saylark dict import [--from vocabulary.sqlite] [--file FILE]   (adds an old store's live terms)
      saylark vocab build [--store FILE] [--projects DIR] [--sessions | --claude DIR] [--with-wispr | --wispr flow.sqlite] [--before YYYY-MM-DD]
      saylark vocab list [--store FILE] [--all] [--state live|candidate|retired|blocked]
      saylark vocab eval <manifest.json> [--store FILE] [--split tune|test] [--ref reference] [--configs C.json | --mode off|ctc|swap|both
                         --termLimit N --confidence 0.6 --context ...] [--cache asr-cache.jsonl] [--per-term] [--out FILE]
      saylark vocab explain <manifest.json> <id> | <file.wav> [--store FILE] [--mode both] [--context]
    """

let args = Arguments(CommandLine.arguments.dropFirst())
do {
    switch args.command {
    case "transcribe": try await TranscribeCommand.run(args)
    case "bench": try await BenchCommand.run(args)
    case "seed": try await SeedCommand.run(args)
    case "seed-terms": try SeedTermsCommand.run(args)
    case "vocab": try await VocabCommand.run(args)
    case "dict": try DictCommand.run(args)
    case "simulate": try await SimulateCommand.run(args)
    case "doctor": try await DoctorCommand.run(args)
    case "insert-test": InsertTestCommand.run(args)
    case "version": print("saylark \(Saylark.version)")
    default:
        print(usage)
        exit(args.command == nil ? 0 : 2)
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
