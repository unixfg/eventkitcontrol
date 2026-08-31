# Releasing eventkitcontrol

Pushing a version tag such as `v1.0.2` starts
`.github/workflows/release.yml`; maintainers do not build or upload release
files from their own Macs. The workflow accepts only a three-part version tag
whose commit is on `main` and whose version matches the application metadata.
It publishes one `.pkg` for Apple Silicon Macs running macOS 14 or later, plus
a checksum and proof of which GitHub workflow built it.

The workflow uses the hosted `${{ github.token }}` for GitHub publication, so
release execution does not depend on a maintainer workstation's `gh`
authentication.

## What the release protections mean

Several independent checks protect different parts of a release:

- The **Developer ID Application signature** identifies who signed the
  executable. Its **secure timestamp** proves that the certificate was valid
  when signing happened, rather than relying on the certificate still being
  unexpired years later.
- The **Developer ID Installer signature** protects the outer `.pkg`. The
  package's **Distribution** file is the installation policy that limits it to
  Apple Silicon, macOS 14 or later, and a system-wide installation.
- **Notarization** is Apple's automated malware and signature check. **Stapling**
  attaches the resulting ticket to the package so a Mac can verify it without
  contacting Apple during installation.
- The **SHA-256 checksum** detects any change to the downloaded bytes.
- The **GitHub attestation** links those bytes to the repository, commit, and
  workflow that produced them. It answers a different question from the Apple
  signature, so the release publishes and verifies both.

## One-time Apple setup

Create dedicated CI credentials rather than exporting day-to-day identities:

1. Create a **Developer ID Application** certificate for signing the executable.
2. Create a **Developer ID Installer** certificate for signing the PKG.
3. Export each certificate and private key to a separate password-protected
   P12. A P12 is an encrypted file containing the certificate and its private
   signing key.
4. In App Store Connect, create a Team API key with the **Developer** role.
   Record its Key ID and Issuer ID and download the P8 file once. The P8 is the
   private API key used only to submit the package for notarization.

Never commit the P12 or P8 files. Keep recoverable copies in the project’s
secret manager; the release runner deletes P12 copies immediately after import,
the signing keychain after product creation, materializes the P8 only for the
notarization step, and deletes it immediately afterward.

## GitHub environment and secrets

Create a GitHub environment named `release`. Restrict its deployment policy to
tags matching `v*`, but do not add a required reviewer if releases should remain
automatic on tag push. Add these environment secrets:

| Secret | Value |
| --- | --- |
| `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64 of the Application P12 |
| `APPLE_DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Application P12 export password |
| `APPLE_DEVELOPER_ID_INSTALLER_P12_BASE64` | Base64 of the Installer P12 |
| `APPLE_DEVELOPER_ID_INSTALLER_P12_PASSWORD` | Installer P12 export password |
| `APPLE_TEAM_ID` | Ten-character Apple Developer Team ID |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64 of the Team API key P8 |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API Key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect Issuer ID UUID |

Because there is no manual environment approval, creating a matching tag is the
release authorization boundary. Add a repository tag ruleset for `v*` that
restricts tag creation, updates, and deletion to the trusted release maintainers
(or a dedicated release team), and do not allow force updates. The workflow also
requires the tagged commit to be reachable from `main`, but that check does not
replace access control on tag creation.

On macOS, `base64 -i path/to/file | pbcopy` copies a file's base64 value without
printing it into the terminal. Base64 is only a transport encoding, not
encryption: the copied text is still the secret. Store it immediately and
clear the clipboard afterward.

Pull-request and `main` CI never reference these secrets. Test executables use
an ad-hoc signature, which is an identity-free local code signature rather than
proof of who built the file. The release job fails instead of substituting that
test signature when a Developer ID credential, timestamp, notarization result,
or validation check is missing.

Ordinary macOS CI combines that ad-hoc-signed executable with an unsigned
installer that is never published. This still tests which file would be
installed, its destination and permissions, the installer rules for
architecture and macOS version, and whether the exact executable can be
extracted again. Only a tagged release adds Developer ID signatures,
timestamps, notarization, the offline ticket, GitHub build proof, and
publication.

## Credential lifecycle

An active Apple Developer Program membership, valid Application and Installer
certificates, and a working App Store Connect API key are all required for a
new release. eventkitcontrol does not use a Developer ID provisioning profile,
so the table below uses Apple's expiration guidance for applications without
one. The credentials do not have the same effect after a release has been made:

- **The Application certificate expires normally:** an already-installed
  command keeps running when the certificate was valid at signing and the
  signature has a secure timestamp. Application-certificate expiry alone does
  not invalidate the executable inside an older package, although that package
  still depends on its Installer certificate. A new release needs a current
  Application certificate; export it as a new P12 and replace only the matching
  GitHub secrets.
- **The Installer certificate expires:** commands that are already installed
  are unaffected, but Apple says an expired Installer-signed package must be
  signed again. Do not promise that the old `.pkg` will continue to open.
  Renew the certificate and publish a new patch release without moving the old
  tag.
- **Developer Program membership lapses:** Apple says already signed Developer
  ID applications continue to run. Older packages still depend on their
  Installer certificate, but new certificates and releases are blocked. Renew
  membership, verify every credential, and release again only after the
  complete workflow passes.
- **A certificate is revoked:** installation or execution may be blocked. Treat
  this as a compromised identity, not as ordinary expiration. Replace it and
  publish a new patch release.
- **The notarization API key is lost, compromised, or revoked:** installed
  commands and already stapled packages are unchanged, but new notarization
  requests are blocked. Revoke and replace the key, then update the P8, Key ID,
  and Issuer ID secrets together.

Check both certificate expiration dates before tagging. See Apple's
[Developer ID certificate guidance](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/),
[secure-timestamp explanation](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates),
[membership renewal guidance](https://developer.apple.com/help/account/membership/renewal/),
and [App Store Connect API key guidance](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).

## Release procedure

Before creating a tag, confirm all of the following:

- the release commit is the current reviewed commit on `origin/main`;
- CI is green for that exact commit;
- the command version and both `Info.plist` version fields agree;
- the matching changelog entry has a real `YYYY-MM-DD` date;
- the version tag does not already exist locally, remotely, or as a GitHub
  release; and
- both certificates and the notarization API key are usable.

These checks happen before tagging because pushing the tag authorizes the
automatic release; there is no later approval prompt.

1. Prepare one release change that sets both version values in `Info.plist`
   and the command version in `Sources/EventKitControl/EventKitControl.swift`
   to the intended semantic version.
2. Finalize that version's `CHANGELOG.md` heading by replacing `Unreleased`
   with the release date in `YYYY-MM-DD` form. Review the entry as user-facing
   release notes: describe behavioral changes and important compatibility or
   safety reasoning, not just commit subjects. Keep its prose self-contained;
   the workflow copies that version's entry and any document-level Markdown
   link definitions, not neighboring version entries.
3. Run the local checks in `CONTRIBUTING.md`, then merge the release change to
   `main` only after CI succeeds.
4. From the exact merged commit on `main`, create and push the matching tag,
   preferably as a signed annotated tag:

   ```bash
   git tag -s v1.0.2 -m "eventkitcontrol v1.0.2"
   git push origin v1.0.2
   ```

The tag starts the workflow automatically. Do not create the GitHub release by
hand: the workflow requires exactly one dated changelog entry matching the tag,
prepends that entry and installation instructions to GitHub's generated commit
notes, refuses to overwrite an existing release, and publishes only after all
of these gates pass:

- Swift tests pass, the dependency lock is current, and validation does not
  silently choose different dependency versions.
- Exactly one Application certificate and one Installer certificate belong to
  the expected Apple team.
- The executable is Apple Silicon-only, requires macOS 14, contains the correct
  Calendar and Reminders permission descriptions, and has the expected Apple
  signature, runtime protections, and timestamp.
- The installer contains only the executable, places it at
  `/usr/local/bin/eventkitcontrol`, runs no installer scripts, and refuses Intel
  Macs or macOS versions older than 14.
- The outer installer has the expected Installer signature and timestamp.
- Apple accepts the package for notarization, its ticket is attached, and
  Gatekeeper accepts the final file.
- A clean-machine-style installation check confirms the installed owner and
  executable permissions.
- The final checksum and GitHub checks tie the published files to their exact
  workflow and commit.

| Failure state | Safe response |
| --- | --- |
| A hosted service failed, no GitHub release exists, and no source change is needed | Rerun the workflow for the same tag |
| A release already exists, or any source, metadata, package, or documentation must change | Make a new patch release and a new tag; never move the published tag |

## Verify a downloaded release

```bash
shasum -a 256 -c eventkitcontrol-v1.0.2-macos-arm64.pkg.sha256
pkgutil --check-signature eventkitcontrol-v1.0.2-macos-arm64.pkg
spctl --assess --type install --verbose=4 eventkitcontrol-v1.0.2-macos-arm64.pkg
gh attestation verify eventkitcontrol-v1.0.2-macos-arm64.pkg \
  --repo unixfg/eventkitcontrol
gh attestation verify eventkitcontrol-v1.0.2-macos-arm64.pkg.sha256 \
  --repo unixfg/eventkitcontrol
```

Each command proves something different:

- `shasum` proves the downloaded bytes match the published checksum.
- `pkgutil` shows the Installer signing chain and signer identity.
- `spctl` asks Gatekeeper whether macOS currently accepts the package for
  installation.
- `gh attestation verify` connects both files to the GitHub workflow and commit
  that produced them. It uses the GitHub CLI and requires network access.

The checksum and Apple signature checks do not need GitHub authentication.

After publication, download the assets from the release rather than reusing the
runner's copies, run the checks above, and confirm that the installed command's
version matches the tag. Apple signature and checksum verification prove
different properties; neither substitutes for checking which GitHub workflow
and commit produced the files.
