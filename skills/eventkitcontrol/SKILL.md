---
name: eventkitcontrol
description: "Read and manage Apple Calendar events and Reminders with the eventkitcontrol CLI on macOS. Use for agenda queries, event and reminder changes, calendar administration, aliases, and troubleshooting eventkitcontrol commands."
---

# eventkitcontrol

Use the installed `eventkitcontrol` executable to work with the current macOS
user's Calendar and Reminders accounts. Prefer its JSON output for selecting
targets and inspecting results.

## Check the environment

- Run on the Mac that holds the user's accounts: Apple Silicon, macOS 14 or
  later. EventKit operations cannot run on Linux or access another Mac's data
  just because this repository is checked out there.
- Locate the executable with `command -v eventkitcontrol`, then inspect
  `eventkitcontrol --version` and the relevant command's `--help`, for example
  `eventkitcontrol update event --help`. Follow the installed command's flags
  if its version differs from this guide.
- If installation is needed, use the signed, notarized Apple Silicon package
  and accompanying SHA-256 file from the
  [project releases](https://github.com/unixfg/eventkitcontrol/releases).
  Verify the checksum before opening the package. It installs
  `/usr/local/bin/eventkitcontrol`. Source builds require full Xcode 26 or later
  with Swift 6; run `./Scripts/build-artifact.sh` from the app repository and
  use the signed executable path it prints.
- Run normal commands as the intended macOS user. Access is requested only for
  the entity being used. Calendar and Reminders permissions are separate;
  manage them in System Settings → Privacy & Security → Calendars / Reminders.
  Grants to another EventKit app do not carry over to this executable.

## Discover targets

Use only the discovery command needed for the task:

```bash
eventkitcontrol list calendars
eventkitcontrol list reminder-lists
eventkitcontrol alias list
```

The collection keys are `calendars`, `reminderLists`, and `aliases`; each result
also has `count` and `status`. Calendar/list objects expose `id`, `title`,
`source`, `allowsModifications`, and `immutable`. Match both title and account
source when names repeat. Use returned IDs or verified aliases, and resolve any
remaining target ambiguity before editing.

Event calendars and reminder lists are different targets. `--calendar` is
required for event queries and creation; `--list` is required for reminder
queries and creation. Event queries accept comma-separated calendar IDs or
aliases; reminder queries accept one list. Bare display names are not aliases.

In the examples, set `CALENDAR_ID`, `REMINDER_LIST_ID`, `EVENT_ID`, and
`REMINDER_ID` from discovery results as needed. Replace example titles and dates
with the user's requested values. Aliases such as `work` and `personal` must
already exist before using them.

## Read events and reminders

```bash
eventkitcontrol today --calendar "$CALENDAR_ID"
eventkitcontrol tomorrow --calendar "$CALENDAR_ID" --availability busy
eventkitcontrol next --calendar "$CALENDAR_ID" --count 5 --days 90
eventkitcontrol list events --calendar work,personal \
  --from "2026-10-01T00:00:00-04:00" --to "2026-10-08T00:00:00-04:00" \
  --search "planning"
eventkitcontrol show event "$EVENT_ID"

eventkitcontrol list reminders --list "$REMINDER_LIST_ID" --completed false
eventkitcontrol list reminders --list "$REMINDER_LIST_ID" --search "milk"
eventkitcontrol show reminder "$REMINDER_ID"
```

- `today` and `tomorrow` use the Mac's local day. `next` defaults to one event
  over 90 days, sorts by start time, and includes events already in progress.
  `--count` must be positive; `--days` accepts 1–1461. Explicit event query
  ranges have the same 1461-day maximum and require `--to` after `--from`.
- `--search` is a case-insensitive substring match across event title,
  location, and notes, or reminder title and notes. Event availability filters
  are `busy`, `free`, `tentative`, `unavailable`, and `notSupported`.
- Omit `--completed` to get both completed and incomplete reminders; supply
  `true` or `false` to filter.
- Event objects include `calendar`, dates, `alarms`, `recurrenceRules`,
  `selector`, `detached`, and `attendees`. For recurring or detached events,
  `show event` also needs the occurrence selector described below.

## Handle dates precisely

Timed inputs, including reminder `--due` and query `--from`/`--to`, require
complete ISO 8601 timestamps with `Z` or an explicit offset, such as
`2026-10-05T09:00:00-04:00`. Compact offsets (`-0400`) and one through nine
fractional-second digits are accepted. Resolve the requested timezone and its
offset for the target date; do not silently treat local wall time as UTC.
Output timestamps use the Mac's local timezone.

All-day event inputs use `YYYY-MM-DD`, and the end day is exclusive. A one-day
event on October 5 uses start `2026-10-05` and end `2026-10-06`. Creation uses
the flag `--all-day`; updating dates requires the option `--all-day true|false`.
For any event date update, supply **all three** of `--start`, `--end`, and
`--all-day`, even when changing only the start time.

## Apply requested changes

All mutation commands support `--dry-run`. For an existing item, first obtain
its exact ID and current snapshot. Preview a proposed mutation and inspect its
target and `changes` before applying it. If the request already authorizes
that exact change, continue without asking for redundant confirmation. A
preview-only request stops at the preview; uncertainty about the target or an
unexpected loss of data needs resolution before saving.

Dry runs validate and preview without saving or deleting EventKit data,
changing aliases, or sending locations to the geocoder. They can still require
macOS Calendar or Reminders access. Apply an authorized preview by rerunning
the command without `--dry-run` and adding any required deletion flag.

```bash
# Create a timed event or a one-day all-day event.
eventkitcontrol add event --calendar "$CALENDAR_ID" --title "Planning" \
  --start "2026-10-05T09:00:00-04:00" --end "2026-10-05T10:00:00-04:00" \
  --dry-run
eventkitcontrol add event --calendar "$CALENDAR_ID" --title "Day off" \
  --start 2026-10-05 --end 2026-10-06 --all-day --dry-run

# Update only supplied fields; date changes require the complete date tuple.
eventkitcontrol update event "$EVENT_ID" --title "Project planning" --dry-run
eventkitcontrol update event "$EVENT_ID" \
  --start "2026-10-05T10:00:00-04:00" --end "2026-10-05T11:00:00-04:00" \
  --all-day false --dry-run

eventkitcontrol add reminder --list "$REMINDER_LIST_ID" --title "Submit report" \
  --due "2026-10-05T17:00:00-04:00" --priority 1 --notes "Include receipts" \
  --dry-run
eventkitcontrol update reminder "$REMINDER_ID" --title "Submit expenses" --dry-run
eventkitcontrol complete reminder "$REMINDER_ID" --dry-run
eventkitcontrol update reminder "$REMINDER_ID" --completed false --dry-run
```

Events also support `--location`, `--notes`, `--url`, `--availability`, and
alarms. Settable availability values are `busy`, `free`, `tentative`, and
`unavailable`; `notSupported` is only a filter/output value. Reminder updates
support `--title`, `--due`, `--priority`, `--notes`, and `--completed true|false`.
Priority accepts every integer 0–9: 0 means none, 1 high, 5 medium, and 9 low.

Read [advanced operations](references/advanced-operations.md) before creating
recurrence rules, replacing or clearing alarms, geocoding locations, or managing
event calendars and aliases.

### Recurring occurrences

An event ID alone is insufficient for recurring events, including detached
occurrences. Copy `selector.occurrenceDate` into `--occurrence` and
`selector.expectedStart` into `--expected-start`, unchanged, from the chosen
query result. Use both flags on **show, update, and delete**, including previews:

```bash
eventkitcontrol show event "$EVENT_ID" \
  --occurrence "$OCCURRENCE_DATE" --expected-start "$EXPECTED_START"
eventkitcontrol update event "$EVENT_ID" --title "Rescheduled planning" \
  --occurrence "$OCCURRENCE_DATE" --expected-start "$EXPECTED_START" --dry-run
```

Set those variables from the same occurrence's selector. The original occurrence
date and current start can differ after a move; an all-day occurrence can even
retain a timestamp selector. Never reconstruct either value from the displayed
day. For a move, `--expected-start` is the observed old start, while `--start`
is the requested new start.

On a missing, stale, or ambiguous selector, re-list the relevant date range and
resolve the target again. Never drop the selector to force an operation through.
Do not supply selectors for non-recurring events. Updates and deletions affect
one occurrence only; whole-series and future-occurrence edits are unsupported.

### Deletions

After identifying and previewing the requested target, actual event and reminder
deletions require `--yes`:

```bash
eventkitcontrol delete event "$EVENT_ID" --dry-run
eventkitcontrol delete event "$EVENT_ID" --yes
eventkitcontrol delete reminder "$REMINDER_ID" --dry-run
eventkitcontrol delete reminder "$REMINDER_ID" --yes
```

For a recurring event, include its selector pair on both commands. Calendar
deletion uses `--confirm` with the resolved calendar ID instead; see the advanced
reference. These flags implement an already-authorized deletion and do not
expand the user's request.

## Interpret results and recover

JSON is the default; `--format csv` and `--format text` are also available.
`--time-format rfc3339` is the default timestamp rendering; `compact` emits
numeric offsets such as `-0400` for parsers that require them. Prefer JSON for
mutation previews so nested `changes` and selector values remain easy to use.

Successful mutations report `dryRun` and `applied`. A preview has `dryRun: true`
and `applied: false`; a saved change has `dryRun: false` and `applied: true`.
Completing an already-completed reminder is a successful no-op with
`alreadyCompleted: true` and `applied: false`. Update previews retain the current
item snapshot and put proposed values in `changes`, so the snapshot alone is
not the proposed result. Verify a saved result using its returned item or a
fresh query; after moving a recurring event, use its refreshed selector.

Errors go to stderr in the selected format. JSON errors contain `status`,
`error`, `code`, and `exitCode`. Keep stderr separate from successful JSON when
scripting, and preserve the CLI's exit status across pipelines.

| Exit | Meaning | Next action |
| --- | --- | --- |
| 0 | Success, including previews and no-ops | Inspect `dryRun` and `applied` for mutations. |
| 64 | Invalid input | Check command help, required flag pairs, dates, and selectors. |
| 2 | Calendar or Reminders permission denied | Resolve access in System Settings on the target Mac. |
| 1 | Operation failure | Read the error; rediscover IDs, check writability or account restrictions as appropriate. |

After an uncertain write outcome, query before retrying a creation to avoid
duplicates. A successful local save does not establish that another device has
finished syncing.

## Respect the supported scope

- Recurrence rules can be created but not edited.
- Events and reminders cannot be moved to another calendar or list.
- Attendees and reminder URLs are read-only. Event URLs can be set but not
  cleared; reminder due dates cannot be cleared.
- Reminder lists can be discovered and used but not created, edited, or deleted.
- Travel time is not exposed. Fixed-date, location-based, and custom alarm
  details can be inspected but cannot be recreated when replacing alarms.

If the request depends on one of these unsupported operations, explain that
limit instead of inventing flags or substituting a destructive recreation.
