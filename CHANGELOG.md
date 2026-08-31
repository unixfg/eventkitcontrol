# Changelog

This file explains what changed, what users will notice, and why some behavior
deliberately differs from the project this one began from. A version marked
`Unreleased` has not yet been published.

## 1.0.0 - Unreleased

This is the first independent eventkitcontrol release. It began from
[the original project's exact source commit][fork-point], but it now has its
own command name, configuration, output, build, and release process. It does
not promise compatibility with the original project.

Most changes follow one rule: if the command cannot determine exactly what the
user meant, or cannot verify that a change is safe, it stops before modifying
Calendar or Reminders data.

### Changes users will notice

- Every command that changes data supports `--dry-run`. A dry run validates the
  request and shows what would change, but does not save or delete anything,
  geocode a location, or rewrite the alias file.
- Deleting an event or reminder requires `--yes`. Deleting a calendar requires
  its exact resolved ID as confirmation. This makes it harder for a misspelled
  alias or copied command to delete the wrong object.
- Recurring events must be selected by both their original occurrence time and
  their current expected start time. An ID alone does not reliably distinguish
  one occurrence, and EventKit may return an unexpected member of the series.
  The command stops if either time is missing or out of date, or if the pair
  does not identify exactly one event.
- Calendar creation requires an exact source ID. The command no longer guesses
  which iCloud, Exchange, or local account should own a new calendar.
- Event calendars, reminder lists, and account sources have separate discovery
  commands. Each operation requests only the Calendar or Reminders permission
  it actually needs.
- Location geocoding is off by default because it sends location text to
  Apple's geocoder. With `--geocode-location`, lookup must finish successfully
  before the event is changed. Dry runs never perform the lookup.
- Invalid dates, identifiers, URLs, colors, priorities, number ranges, and
  recurrence combinations are rejected instead of being silently adjusted or
  partly accepted. Event date updates require the complete start, end, and
  all-day state so the command can validate the result as a whole.
- Event searches are limited to a four-year date range, and operations that
  wait for EventKit or geocoding have time limits. A system service that never
  calls back now produces an error instead of leaving the command hanging
  forever.
- Reminder due dates are interpreted with the Gregorian calendar regardless of
  the user's display-calendar preference. This prevents the same stored date
  components from meaning different days under another calendar system.

### Alarms: all-or-nothing updates

The old parsing approach discarded alarm values it could not understand. That
made a typo dangerous: `--alarms "10,typo"` could silently become a single
10-minute alarm. If every value was invalid, the parsed list became empty and
an update could remove all existing alarms.

Alarm input is now parsed completely before any event is changed. If one entry
is empty, malformed, repeated, not a normal decimal number (such as `NaN` or
infinity), or out of range, the entire request fails and the existing alarms
remain untouched. Removing alarms is a separate, deliberate operation using
`--clear-alarms`.

Changing an alarm list replaces the complete alarm records stored by Calendar,
not just their times. Fixed-date alarms and extra details such as custom
actions, sounds, email, procedures, proximity triggers, or locations may
therefore be lost. A dry run shows the full before-and-after alarm lists and
warns about details the command cannot recreate.

### Alarms: the round-trip paradox

Alarm input has an unusual but established sign rule:

- `15` and `-15` both mean 15 minutes **before** an event.
- Only an explicit `+15` means 15 minutes **after** an event.

That leading plus sign is part of the input language, but JSON numbers do not
preserve it. Imagine describing an alarm 15 minutes after the start as
`minutesBeforeStart: -15`. The value looks reasonable—negative minutes before
is after—but feeding the numeric `-15` back into `--alarms` schedules the alarm
15 minutes **before** the event. The output appears reusable while reversing
the meaning.

eventkitcontrol avoids that round-trip paradox by exposing EventKit's exact
signed seconds as `alarms[].offsetSeconds` and
`relativeAlarmOffsetsSeconds`: `-900` is before the start and `900` is after.
The field names make the units and direction explicit, and the documentation
does not present them as reusable minute-based `--alarms` input. Exact seconds
also preserve offsets that are not a whole number of minutes.

### Why `--travel-time` was removed

Apple's public EventKit API does not provide a supported way to set an event's
travel time. The inherited implementation tried to set an undocumented
property named `travelTime` by spelling that property name at runtime. That
technique can work on some macOS versions, but the compiler cannot verify it
and Apple may change it without notice. A failure can also bypass the normal
error handling that lets the command stop cleanly and explain what went wrong.

Keeping the option would imply that eventkitcontrol could validate and safely
report the result when it could not actually make that guarantee. The option
was therefore removed in favor of using documented EventKit APIs only. This is
a safety boundary, not a claim that the earlier implementation never worked.
If Apple provides a supported public API in the future, the feature can be
reconsidered on that basis.

### Configuration and output safety

- Aliases now use `~/.eventkitcontrol/config.json`. Updates lock the complete
  read-change-write operation and replace the file in one final step, so two
  commands cannot silently overwrite each other's changes or leave a partly
  written file after a crash.
- The normal configuration directory is kept private. Wrong owners, unexpected
  file types, links that could redirect a write, extra access-control entries,
  oversized files, and malformed data are rejected. Ordinary mode mistakes in
  the normal directory are repaired to private values.
- Errors have stable machine-readable codes and process exit statuses, making
  scripts able to distinguish invalid input, permission denial, and an
  operation failure.
- CSV output protects values beginning with spreadsheet formula characters.
  JSON and text output make terminal control characters visible instead of
  allowing calendar or reminder text to act as terminal instructions.

### Build and release changes

- The inherited executable name, configuration directory, and build script
  were replaced. Supported builds target Apple Silicon and macOS 14 or later.
- Dependencies are locked so CI and release builds use the reviewed versions
  recorded in the repository.
- CI checks the executable, installer contents, install location, permissions,
  and package metadata. Releases are signed, checked by Apple's notarization
  service, and include Apple's ticket for offline verification. A SHA-256
  checksum detects changed download bytes, while GitHub records which workflow
  and commit produced the files.

### Known limitations

- Alarm changes can create alarms at, before, or after the event start.
  Existing fixed-date alarms are shown, and the command warns when custom
  details are present, but it cannot fully display or recreate those details.
- Recurrence rules can be created but not edited after creation.
- A recurring event update or deletion affects one exactly selected
  occurrence. Whole-series and “this and future” changes are not available.
- Items cannot be moved between calendars or reminder lists.
- Event URLs can be set but not explicitly cleared. Reminder URLs are
  read-only, and reminder due dates cannot yet be explicitly cleared.
- Attendees are read-only.
- Reminder lists can be discovered and used, but not created, updated, or
  deleted.

[fork-point]: https://github.com/unixfg/eventkitcontrol/commit/79a7c86124c04a93180ce2aeb281a5e3e483f88a
