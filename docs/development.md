# Development notes

Tools for working on Saylark itself. None of these are needed to use the app.

## Debug flags on the app binary

The app executable takes a few flags. Run them on the binary from `swift build`
(`.build/debug/SaylarkApp`), from the repo root. None of them install event taps, open the mic,
touch the clipboard or ask for permissions.

```sh
swift build --product SaylarkApp
.build/debug/SaylarkApp --ui-render --out /tmp/saylark-ui      # every screen to PNG, light and dark, with sample data
.build/debug/SaylarkApp --pill-render all --out /tmp/pill       # pill scenarios to MP4 (needs ffmpeg) + contact sheets
.build/debug/SaylarkApp --pill-lab                              # a window for trying pill states by hand
.build/debug/SaylarkApp --fake-engine                           # the whole app on a fake engine and sample takes
```

`--ui-render` builds each window exactly as the app does but never puts it on screen. The sample
takes and dictionary come from `Sources/SaylarkUI/Fake/`; the dictionary is written to a temp
folder, never to your real `dictionary.txt`.

`--pill-render` animates the pill with recorded voice envelopes from `data/envelopes/` (gitignored).
Without envelopes only the silent card scenarios render. Make envelopes from your own clips with
`--pill-envelopes <manifest.json> --out data/envelopes`; the manifest lists WAV files with an id,
duration and transcript. The README screenshots were rendered with `--ui-render`, and the pill
animation with `--pill-render` on an envelope made from a synthetic voice.

## Developer commands in the CLI

```sh
saylark simulate clip.wav --script handsfree --send   # a whole take with a fake key, mic and clipboard
saylark insert-test                                   # the paste path in its own window, with a private clipboard
saylark bench manifest.json                           # time-to-text and accuracy over a set of clips
saylark vocab build|list|eval|explain                 # the older learned-vocabulary store, for measuring the corrector
saylark dict import --from vocabulary.sqlite          # copy that store's live terms into dictionary.txt
```

Run `saylark` with no arguments for every option. `bench`, `seed` and `vocab eval` work on a
manifest of your own recordings; nothing of the kind ships in the repo.

## Tests

```sh
scripts/test.sh                              # the whole suite
scripts/test.sh --filter DictionaryFileTests # one suite
SL_SCRATCH=.build-test scripts/test.sh       # a separate build folder (parallel worktrees)
```

Tests write recordings to a per-run temp folder, which `test.sh` removes afterwards
(`SL_KEEP_TEST_TMP=1` keeps it).

## Packaging

- `scripts/bundle.sh` builds and signs `build/Saylark.app`.
- `scripts/release.sh` builds the notarized DMG; see [RELEASING.md](../RELEASING.md).
- `scripts/make-icon.sh <icon.png>` rebuilds `packaging/AppIcon.icns` from source art.
- `scripts/make-notices.sh` regenerates `packaging/THIRD_PARTY_NOTICES.txt` after a dependency change.
