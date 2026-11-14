# Releasing Saylark

One command builds a signed, notarized and stapled DMG:

```sh
scripts/release.sh --version 0.1.0
```

It writes these files to `build/`:

| File | What it is |
| --- | --- |
| `Saylark-<version>.dmg` | The release DMG: `Saylark.app` and an `Applications` shortcut to drag it onto |
| `Saylark.dmg` | The same file under a fixed name, so `releases/latest/download/Saylark.dmg` always works |
| `Saylark-<version>.sha256` | SHA-256 checksums of both |
| `Saylark.app` | The signed, stapled app |

The script never launches the app and never asks for or stores a password.

## One-time setup

You need to do this once per Mac.

1. **Developer ID certificate.** In Xcode (Settings > Accounts > Manage Certificates) or at
   developer.apple.com, create a *Developer ID Application* certificate for team `Y8J6V7372T` and
   install it in your login keychain. Check it:

   ```sh
   security find-identity -v -p codesigning    # should list "Developer ID Application: … (Y8J6V7372T)"
   ```

2. **App-specific password.** At [account.apple.com](https://account.apple.com), go to Sign-In and
   Security > App-Specific Passwords and create one (name it "notarytool").

3. **Notarization profile.** Store the credentials in the keychain under the name `saylark`:

   ```sh
   xcrun notarytool store-credentials saylark --apple-id <your Apple ID email> --team-id Y8J6V7372T
   ```

   It prompts for the app-specific password. `release.sh` only refers to the profile by name. If the
   profile is missing, the script stops before building or submitting anything and prints this
   command.

4. **GitHub CLI** (only for `--publish`): `gh auth login`.

## Each release

1. Write the release notes in `release-notes/v<version>.md` (optional; without it, `--publish`
   uses a short generic note).
2. Set the version and build:

   ```sh
   scripts/release.sh --version 0.2.0
   ```

   `--version` writes `CFBundleShortVersionString` in `packaging/Info.plist` and adds 1 to
   `CFBundleVersion` (or pass `--build N`). `packaging/Info.plist` is the only place the app's version
   lives. Without `--version` the script releases the version already there.

   The script then:
   - builds the release app with `scripts/bundle.sh` (Developer ID, hardened runtime, secure timestamp)
   - checks the signature (`codesign --verify --deep --strict`), and that the only executable in the
     bundle is `Contents/MacOS/Saylark`
   - notarizes the app (`notarytool submit --wait`) and staples it, so a copy dragged out of the DMG
     opens even offline
   - builds the DMG with `hdiutil` (app, `Applications` shortcut, Saylark's volume icon), signs it,
     notarizes and staples it
   - checks both with Gatekeeper: `spctl -a -t open --context context:primary-signature -v` on the
     DMG, `spctl -a -vv` on the app
   - writes the checksums

   Each notarization usually takes a few minutes. If Apple rejects a submission, the script prints
   Apple's log and stops.

3. Check the DMG: open it, drag Saylark to Applications on a test Mac (or a fresh user account),
   and run it.
4. Commit the version change, then create the GitHub release:

   ```sh
   git commit -am "Release 0.2.0"
   scripts/release.sh --publish                 # a draft release v0.2.0 with the DMGs and checksums
   ```

   `--publish` needs a clean tree and creates a **draft**. Review it on GitHub and publish it there,
   or publish straight away with `--publish --no-draft --latest`. The release is marked Latest only
   with `--latest` (or when you publish the draft and tick "Set as the latest release"). The README's
   download link, `releases/latest/download/Saylark.dmg`, points at the latest published release, so
   it works only once a release is published and marked Latest.

## Options

```
--version X.Y.Z   set the version in packaging/Info.plist first
--build N         set CFBundleVersion
--no-notarize     stop after the signed DMG (a local check; Gatekeeper rejects it, don't ship it)
--publish         create a GitHub release (draft unless --no-draft)
--no-draft        with --publish, publish immediately
--latest          with --publish, mark it as the latest release
--notes FILE      release notes (default release-notes/v<version>.md)
```

`SL_NOTARY_PROFILE` overrides the profile name, `SL_SIGN_IDENTITY` the signing identity.

## Notes

- The DMG uses `hdiutil` only, so its Finder window has no custom background or icon positions
  (those need Finder scripting). Finder shows Saylark and the Applications shortcut in its default layout.
- The `saylark` command line tool is not in the DMG. People who want it build it from source
  (see the README).
- Keep the same Developer ID for every release. macOS ties the Microphone, Input Monitoring and
  Accessibility permissions to the signature, so a different identity makes users grant them again.
