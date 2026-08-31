# Releasing eventkitcontrol

Tagged releases are built only by `.github/workflows/release.yml`. The workflow
accepts a canonical `vMAJOR.MINOR.PATCH` tag whose commit is reachable from
`main` and whose version matches `Info.plist`. It publishes one Apple
Silicon-only, signed, notarized, and stapled product archive plus its SHA-256
checksum and GitHub artifact attestations. Its Distribution rejects Intel Macs
and macOS versions older than 14.0 before installation.

The workflow uses the hosted `${{ github.token }}` for GitHub publication, so
release execution does not depend on a maintainer workstation's `gh`
authentication.

## One-time Apple setup

Create dedicated CI credentials rather than exporting day-to-day identities:

1. Create a **Developer ID Application** certificate for signing the executable.
2. Create a **Developer ID Installer** certificate for signing the PKG.
3. Export each certificate and private key to a separate password-protected P12.
4. In App Store Connect, create a Team API key with the **Developer** role.
   Record its Key ID and Issuer ID and download the P8 file once.

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

On macOS, `base64 -i path/to/file | pbcopy` copies a file’s base64 value without
printing it into the terminal. Clear the clipboard after storing the secret.

Pull-request and `main` CI never reference these secrets. The release job fails
instead of falling back to ad-hoc signing when a credential, identity,
timestamp, notarization result, or validation check is missing.

Ordinary macOS CI builds a clearly unsigned, unpublished product archive to
exercise the Distribution constraints, payload allowlist, bill of materials,
receipt metadata, and exact binary extraction. Only the tagged release workflow
enables Developer ID signing of the outer product, timestamping, notarization,
stapling, attestation, and publication.

## Release procedure

1. Merge the intended release commit to `main` after CI succeeds.
2. Set both version values in `Info.plist` and the command version in
   `Sources/EventKitControl/EventKitControl.swift` to the intended semantic
   version in the same change.
3. Create and push the matching tag, preferably as a signed annotated tag:

   ```bash
   git tag -s v1.0.0 -m "eventkitcontrol v1.0.0"
   git push origin v1.0.0
   ```

The tag starts the workflow automatically. Do not create the GitHub release by
hand: the workflow refuses to overwrite an existing release and publishes only
after all of these gates pass:

- Swift 6 tests plus lockfile schema, manifest-origin hash, and
  locked-dependency verification
- exactly one valid Application and Installer identity for the expected team
- ARM64-only executable, Developer ID signature, Hardened Runtime, secure
  timestamp, exact EventKit entitlements, embedded plist, and macOS 14 minimum
- one scriptless component payload targeting `/usr/local/bin/eventkitcontrol`,
  wrapped in a system-only ARM64/macOS 14+ product archive
- outer Developer ID Installer signature and trusted timestamp
- clean Apple notarization status and log, followed by stapling and Gatekeeper
  assessment
- installation smoke test with root:wheel ownership and mode `0755`
- final checksum and GitHub provenance attestations

## Verify a downloaded release

```bash
shasum -a 256 -c eventkitcontrol-v1.0.0-macos-arm64.pkg.sha256
pkgutil --check-signature eventkitcontrol-v1.0.0-macos-arm64.pkg
spctl --assess --type install --verbose=4 eventkitcontrol-v1.0.0-macos-arm64.pkg
gh attestation verify eventkitcontrol-v1.0.0-macos-arm64.pkg \
  --repo unixfg/eventkitcontrol
```

The checksum and Apple signature checks do not need GitHub authentication.
Attestation verification uses the GitHub CLI and may require network access.
