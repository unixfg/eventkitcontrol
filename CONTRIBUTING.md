# Contributing to eventkitcontrol

Contributions are welcome. The project favors small, reviewable changes with a
clear description of observable inputs, output, errors, and data changes over
broad rewrites.

## Development environment

The authoritative build and test environment is an Apple Silicon Mac running
macOS 14 or later with Swift 6 from a full Xcode 26 or later installation.
Dependencies must remain reproducible from `Package.resolved`.

## Which checks to run

Run the checks that cover the files and behavior you changed. Every change
should first pass the basic diff check:

```bash
git diff --check HEAD
```

This checks both staged and unstaged changes to tracked files. Add each new file
to the index, or mark it with `git add --intent-to-add PATH`, before running the
command so new files are included too.

For Swift code or dependency changes, validate the locked dependencies, build,
and tests:

```bash
./Scripts/validate-lockfile.sh
swift package dump-package >/dev/null
swift build --product eventkitcontrol --arch arm64 --disable-automatic-resolution
swift test --disable-automatic-resolution
git diff --exit-code -- Package.resolved
```

`--disable-automatic-resolution` matters because a test should not silently
choose different dependency versions or rewrite the lockfile. If
`Package.resolved` changes, review and commit that as a deliberate dependency
change rather than as a side effect of validation.

For privacy descriptions, entitlements, or signing metadata, check the Apple
property-list files:

```bash
plutil -lint Info.plist eventkitcontrol.entitlements
```

For executable, signing, installer, or package-layout changes, build the same
CI-style artifacts without Developer ID credentials. The executable receives
an ad-hoc signature—an identity-free local signature that lets macOS inspect
it—while the test installer remains unsigned:

```bash
mkdir -p .build
CHECK_ROOT="$(mktemp -d .build/eventkitcontrol-contributor.XXXXXX)"
./Scripts/build-artifact.sh --output-dir "$CHECK_ROOT/artifact"
./Scripts/build-package.sh \
  --signing-mode unsigned \
  --output "$CHECK_ROOT/eventkitcontrol-ci-unsigned.pkg" \
  "$CHECK_ROOT/artifact/eventkitcontrol"
```

The fresh directory is intentional. Both builders refuse to overwrite an old
result, which prevents a successful-looking check from accidentally inspecting
files left by an earlier build. Keep the directory for inspection or remove
that exact directory after the checks complete.

Shell, changelog, release-note, or workflow changes should also pass:

```bash
bash -n Scripts/*.sh
shellcheck Scripts/*.sh
PYTHONDONTWRITEBYTECODE=1 \
  python3 -m unittest discover -s Tests/ReleaseNotes -p '*_tests.py'
PYTHONDONTWRITEBYTECODE=1 \
  python3 -m unittest discover -s Tests/Workflow -p '*_tests.py'
```

If `actionlint` is installed, run it as an additional check for GitHub Actions
workflow mistakes. The Python unit tests above run in ordinary CI; signed
release operations remain macOS release-only. Hosted macOS CI also exercises
the real temporary-keychain search-list lifecycle without loading a signing
certificate.

Developer ID signing, notarization, stapling, and publication are release-only
checks documented in the [maintainer release procedure](docs/releasing.md).
Contributors do not need release credentials. If a change affects live EventKit
behavior, report any signed-macOS smoke test separately from unit tests. A live
test is the only way to exercise the real Calendar or Reminders database and
macOS Transparency, Consent, and Control (TCC), the permission system behind the
first-run access prompts. Unit tests cannot prove those system interactions.

## Change and commit hygiene

- Keep one behavioral concern per commit where practical.
- Include a regression test that fails for the original behavior and passes for
  the proposed behavior.
- Separate behavior from formatting, renaming, dependency, platform, and
  packaging changes.
- Preserve unrelated work in the checkout and avoid generated-file churn.
- In the pull-request description, state the reproduction, intended contract,
  exact validation performed, and anything that remains unverified.

Tool-assisted code has the same bar as handwritten code. The person submitting
the change should inspect and understand every line, be able to reproduce the
problem without relying on generated prose, and be willing to own review and
follow-up. A plausible diff or a passing test by itself is not sufficient
evidence that the behavior is correct.

## Preparing a fix for the original project

eventkitcontrol diverged substantially after
[this immutable fork point][fork-point]. Do not offer the large hardening or
rebrand commits as contributions to the original project. They combine
independent product policy, identity, platform, packaging, and behavioral
decisions.

For a possible contribution to the original project:

1. Check its current contribution policy and reproduce the problem against its
   current default branch. A behavior inherited at the fork point may already
   have changed.
2. For a compatibility or policy decision, open an issue or discussion before
   writing a large patch.
3. Create a fresh branch from the original project's current default branch,
   not from this fork's history.
4. Port one behavior and its focused regression test. Preserve the target
   project's names, supported platforms, output contracts, and style unless the
   fix itself requires a deliberate compatibility change.
5. Exclude eventkitcontrol-specific identity, configuration paths, installer,
   signing, architecture, and release policy.
6. Run the target project's own test and build process, then manually inspect
   the complete diff. Report only validation that actually ran.
7. Write the proposal in your own words and remain available to explain or
   revise every part of it. Follow the target project's disclosure policy for
   any development tools used.

The [portability ledger](docs/original-project-portability.md) divides the
squashed safety work into focused candidates, dependencies, tests, and
fork-specific exclusions. It is planning material, not a claim that any change
has been submitted or accepted elsewhere.

[fork-point]: https://github.com/unixfg/eventkitcontrol/commit/79a7c86124c04a93180ce2aeb281a5e3e483f88a
