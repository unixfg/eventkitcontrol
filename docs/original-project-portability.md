# Original-project portability ledger

This ledger reconstructs focused change boundaries from work that entered this
fork in a small number of large commits. It exists to make a careful future
contribution possible without exporting the fork's product decisions or asking
another maintainer to review a generated mega-diff.

Fork point: [`79a7c86124c04a93180ce2aeb281a5e3e483f88a`][fork-point]

## How to use this ledger

This is not a list of ready-made pull requests. Each row is a question worth
investigating separately:

- **Focused candidate** describes one possible fix or design change.
- **Local evidence** points to where eventkitcontrol implements or tests the
  idea. It shows how this fork approached the problem; it does not prove the
  same change belongs in another project.
- **Dependencies and proof still needed** names what must be reproduced,
  tested, or agreed with the maintainer before proposing a change.
- **Status** deliberately says that nothing is ready. “Policy discussion
  first” means the user-facing decision should be agreed before code is
  written. “Conditional design” or “platform work” applies only if the other
  project wants that feature or platform change. “Design evidence only” means
  this fork may be useful as a reference, but its code is too product-specific
  to copy.

For any row, start from the original project's current default branch and prove
that the problem still exists. Create a focused test that demonstrates the
failure, discuss compatibility when behavior would change, and then implement
only that fix on a fresh branch. Validate it with the original project's own
build and test process. This avoids asking another maintainer to untangle this
fork's renaming, packaging, and unrelated safety policy.

| ID | Focused candidate | Local evidence | Dependencies and proof still needed | Status |
| --- | --- | --- | --- | --- |
| P01 | Remove the undocumented travel-time Key-Value Coding setter (runtime property lookup) and CLI option without replacement | Public-API boundary in [`CHANGELOG.md`](../CHANGELOG.md) | Agree on the feature removal; add a CLI-help/API-surface absence assertion or explain why a behavioral test is inapplicable | Policy discussion first |
| P02 | Parse alarm lists atomically and require an explicit clear operation | [`AlarmParsingSafetyTests`](../Tests/EventKitControlTests/SafetyHardeningTests.swift), [`AlarmParsing.swift`](../Sources/EventKitControlCore/AlarmParsing.swift) | Reproduce current partial-parse behavior; review the intentional compatibility break | Not prepared |
| P03 | If alarm-detail output is being added, expose exact seconds and do not claim that a derived minute value can be copied back as input without changing its meaning | [`testAlarmOutputNamesRawEventKitUnitsAsSeconds`](../Tests/EventKitControlTests/SafetyHardeningTests.swift), [`alarmToDict`](../Sources/EventKitControlCore/EventKitManager.swift) | This is conditional output guidance, not a fork-point bug fix; agree on the target output first | Conditional design |
| P04 | Strictly parse ISO timestamps and Gregorian civil dates | [`StrictDateParsingSafetyTests`](../Tests/EventKitControlTests/SafetyHardeningTests.swift), [`DateParsing.swift`](../Sources/EventKitControlCore/DateParsing.swift) | Reproduce normalized/trailing input acceptance and review compatibility | Not prepared |
| P05 | Reject malformed, incompatible, duplicated, or ambiguously ended recurrence rules | [`InputValidationSafetyTests`](../Tests/EventKitControlTests/SafetyHardeningTests.swift), [`InputValidation.swift`](../Sources/EventKitControlCore/InputValidation.swift) | Depends on P04 for date endings; split further if target review size warrants it | Not prepared |
| P06 | Select recurring occurrences by original occurrence and expected current start, never by first-match fallback | Selection model tests in [`EventKitSafetyModelTests`](../Tests/EventKitControlTests/SafetyHardeningTests.swift), resolution in [`EventKitManager.swift`](../Sources/EventKitControlCore/EventKitManager.swift) | P04; add a test that exercises real selection through EventKit or through a replaceable test implementation | Not prepared |
| P07 | Preview changes without writes, deletes, configuration changes, or network geocoding | Preview implementations in [`EventKitManager.swift`](../Sources/EventKitControlCore/EventKitManager.swift) | Add no-write tests using a replaceable EventKit store; P02 and P06 are needed for the complete event preview contract | Not prepared |
| P08 | Require explicit confirmation for destructive operations | Delete commands in [`EventKitControl.swift`](../Sources/EventKitControl/EventKitControl.swift) | Add CLI parsing/confirmation tests; P07 if dry-run is offered as the safe alternative | Not prepared |
| P09a | List sources and require an exact source ID for event-calendar creation | Source operations in [`EventKitManager.swift`](../Sources/EventKitControlCore/EventKitManager.swift) | Add focused source-selection and save-failure tests; this removes guessed-source behavior | Not prepared |
| P09b | Separate event calendars from reminder lists and scope access accordingly | List/access operations in [`EventKitManager.swift`](../Sources/EventKitControlCore/EventKitManager.swift) | Add focused entity-separation and access-scope tests; review mixed-container compatibility | Not prepared |
| P10a | Protect callback state from simultaneous access and classify permission failures separately | [`EventKitSafetyModelTests`](../Tests/EventKitControlTests/SafetyHardeningTests.swift), callback wrappers in [`EventKitManager.swift`](../Sources/EventKitControlCore/EventKitManager.swift) | Add tests that control callback order through a replaceable EventKit boundary and exercise race conditions | Not prepared |
| P10b | Bound access and reminder-fetch waits and cancel timed-out fetches | Timeout paths in [`EventKitManager.swift`](../Sources/EventKitControlCore/EventKitManager.swift) | P10a; add deterministic timeout and cancellation tests | Not prepared |
| P11a | Make geocoding opt-in and finish it before changing or saving an event | Geocoding/update paths in [`EventKitManager.swift`](../Sources/EventKitControlCore/EventKitManager.swift) | P07 for dry-run; add tests with a replaceable geocoder for order, failure, timeout, cancellation, and no-save behavior | Not prepared |
| P11b | Migrate geocoding to the current MapKit API while keeping the older fallback only on macOS versions where it exists | Version-guarded paths in [`EventKitManager.swift`](../Sources/EventKitControlCore/EventKitManager.swift) | Decide the compiler, SDK, and minimum macOS versions separately; depends on protected callback state | Conditional platform work |
| P12a | Introduce a configuration store that reports errors, can be replaced in tests, and validates its data shape and size | Schema tests in [`ConfigManagerTests`](../Tests/EventKitControlTests/EventKitControlTests.swift), [`ConfigManager.swift`](../Sources/EventKitControlCore/ConfigManager.swift) | Preserve the target namespace and decide migration behavior | Not prepared |
| P12b | Lock the complete configuration read-change-write operation and publish the new file in one step, so concurrent updates are not lost and readers never see a partial file | Concurrency and interrupted-write tests in [`ConfigManagerTests`](../Tests/EventKitControlTests/EventKitControlTests.swift) | P12a; adapt locking and disk-durability calls to the target platform policy | Not prepared |
| P12c | Protect configuration paths, ownership, modes, links, file types, and access-control lists (ACLs); repair private modes only in the normal configuration directory and reject unsafe modes in override directories | Filesystem-hardening tests in [`ConfigManagerTests`](../Tests/EventKitControlTests/EventKitControlTests.swift) | P12a and P12b; review platform and filesystem assumptions independently | Not prepared |
| P13a | Render structured errors on stderr with stable exit semantics | Payload/error tests in [`SafeOutputRenderingTests`](../Tests/EventKitControlTests/SafetyHardeningTests.swift), routing in [`EventKitControl.swift`](../Sources/EventKitControl/EventKitControl.swift) | Agree on compatibility for codes, stream, and exit statuses; add a CLI stderr/stdout integration test | Not prepared |
| P13b | Neutralize spreadsheet formulas and terminal/bidirectional controls | Injection tests in [`SafeOutputRenderingTests`](../Tests/EventKitControlTests/SafetyHardeningTests.swift), [`JSONOutput.swift`](../Sources/EventKitControlCore/JSONOutput.swift) | Reproduce in each target output format | Not prepared |
| P13c | Preserve nested dry-run metadata when rendering CSV or text | Metadata test in [`SafeOutputRenderingTests`](../Tests/EventKitControlTests/SafetyHardeningTests.swift) | P07; confirm the target row-flattening contract | Not prepared |
| P14 | Convert reminder due components with the Gregorian calendar | Reminder conversion test in [`EventKitSafetyModelTests`](../Tests/EventKitControlTests/SafetyHardeningTests.swift) | Reproduce under a non-Gregorian user calendar | Not prepared |
| P15a | Bound shortcut and explicit EventKit query ranges | [`DateRangesTests`](../Tests/EventKitControlTests/EventKitControlTests.swift) | Agree on the target's maximum range | Not prepared |
| P15b | Reject invalid identifiers, priorities, and colors before access prompts | Scalar tests in [`InputValidationSafetyTests`](../Tests/EventKitControlTests/SafetyHardeningTests.swift) | Review compatibility for each input independently | Not prepared |
| P15c | Reject invalid URLs, updates with no change options, and incomplete event date-update shapes before access prompts | Validation paths in [`EventKitControl.swift`](../Sources/EventKitControl/EventKitControl.swift) | Add focused CLI tests; P04 applies to the date-shape portion only | Not prepared |
| P16 | Embed the `Info.plist` permission explanations required for macOS Calendar and Reminders prompts, then validate the executable | Build design in [`Package.swift`](../Package.swift), fork-specific proof in [`validate-artifact.sh`](../Scripts/validate-artifact.sh) | Adapt rather than copy the validator: it hardcodes this fork's identity, architecture, entitlements, and macOS baseline | Design evidence only |
| P17 | Carry compile-only Swift 6 sendability, `FileHandle`, and test adaptations separately from behavior changes | [`ConfigManager.swift`](../Sources/EventKitControlCore/ConfigManager.swift), [`EventKitControl.swift`](../Sources/EventKitControl/EventKitControl.swift), [`EventKitControlTests.swift`](../Tests/EventKitControlTests/EventKitControlTests.swift) | Decide the target compiler matrix; do not bundle MapKit, dependency, minimum-OS, or product-policy changes | Not prepared |

## Standing rules

1. **Reproduce on the original project's current default branch.** The fork
   point is historical; the problem may already be fixed or the surrounding
   behavior may have changed.
2. **Reimplement an accepted fix on a fresh branch.** Cherry-picking the large
   fork commits would also import unrelated identity and product-policy changes.
3. **Include a focused regression test.** The test demonstrates the actual
   failure and prevents it from returning. For a pure option removal, test that
   the option is absent or explain why a behavioral test would not be useful.
4. **Leave unrelated formatting and refactoring out.** A smaller diff is easier
   to understand, review, and merge safely.
5. **Preserve the original project's contracts unless the proposal is
   explicitly about one of them.** This avoids accidental changes to names,
   supported systems, dependencies, configuration, or output.
6. **Treat generated suggestions as drafts.** The submitter should understand
   every line, run the original project's checks, and report what remains
   uncertain so authorship and follow-up have a clear human owner.

## Fork-specific exclusions

The following belong to eventkitcontrol and should not accompany behavioral
fixes prepared for the original project:

- product, target, module, path, bundle, configuration, and command renaming;
- the Apple-Silicon-only and macOS 14+ product policy;
- Developer ID identities, package receipt identifiers, PKG layout,
  notarization, stapling, attestations, and release-secret handling;
- identity-retirement CI checks and repository-specific agent guidance; and
- product-package validator fixes that only apply to this distribution stack.

[fork-point]: https://github.com/unixfg/eventkitcontrol/commit/79a7c86124c04a93180ce2aeb281a5e3e483f88a
