# eventkitcontrol

[![CI](https://github.com/unixfg/eventkitcontrol/actions/workflows/ci.yml/badge.svg)](https://github.com/unixfg/eventkitcontrol/actions/workflows/ci.yml)

A safety-first native macOS command-line tool for managing Calendar events and
Reminders through EventKit. Mutations are explicit and previewable, destructive
operations fail closed, and output is JSON by default with CSV and plain-text
formats available for scripting.

## Features

- List, create, update, and delete calendar events
- List, create, update, complete, and delete reminders
- Quick date-range shortcuts: `eventkitcontrol today`, `eventkitcontrol tomorrow`, `eventkitcontrol next`
- Search and filter (`--search`, `--availability busy`) without piping through jq
- Calendar aliases (use friendly names instead of UUIDs)
- JSON, CSV, or plain-text output (`--format json|csv|text`)
- RFC 3339 or jq-friendly compact timestamps (`--time-format rfc3339|compact`)
- Full EventKit integration with proper permission handling
- Support for iCloud, Exchange, and local calendars

## Requirements

- Apple Silicon Mac
- macOS 14.0 (Sonoma) or later
- Building from source additionally requires Swift 6 from Xcode 26 or later.
  Use a full Xcode installation; prebuilt packages have no build-time
  requirements.

## Installation

### Signed package

Tagged releases publish an Apple Silicon product archive signed with Developer
ID, notarized by Apple, and stapled for offline Gatekeeper validation. Installer
rejects Intel Macs and macOS releases older than 14.0 before changing the
system. Replace the tag below with the release you want:

```bash
TAG=v1.0.0
PACKAGE="eventkitcontrol-${TAG}-macos-arm64.pkg"
curl -fLO "https://github.com/unixfg/eventkitcontrol/releases/download/${TAG}/${PACKAGE}"
curl -fLO "https://github.com/unixfg/eventkitcontrol/releases/download/${TAG}/${PACKAGE}.sha256"
shasum -a 256 -c "${PACKAGE}.sha256"
sudo installer -pkg "$PACKAGE" -target /
eventkitcontrol --version
```

The product archive installs `/usr/local/bin/eventkitcontrol`. It contains no
installer scripts and does not install an upstream compatibility command.

Install a newer PKG the same way to upgrade. To uninstall the executable and
forget its installer receipt:

```bash
sudo rm /usr/local/bin/eventkitcontrol
sudo pkgutil --forget io.github.unixfg.eventkitcontrol.pkg
```

Uninstalling leaves `~/.eventkitcontrol` in place so configuration is not
silently deleted.

### Build from source

Clone the repository and run the supported artifact builder:

```bash
git clone https://github.com/unixfg/eventkitcontrol.git
cd eventkitcontrol
./Scripts/build-artifact.sh
```

The script builds ARM64 from the checked-in dependency lock, applies an ad-hoc
Hardened Runtime signature with the EventKit entitlements, validates the binary,
removes its isolated build scratch data, and prints the binary's unique path
under `.build/eventkitcontrol-artifact.*`. It creates no archive and installs
nothing. Successful `main` CI runs also expose short-lived, ad-hoc-signed
snapshot archives; tagged PKGs are the supported distribution.

### Permissions

On first run, macOS will prompt for access to the data the command touches.
Event-calendar and reminder-list commands are separate, so a reminders-only
workflow never triggers the Calendar prompt (and vice versa). Manage permissions
in **System Settings → Privacy & Security → Calendars / Reminders**.
eventkitcontrol has its own bundle identity, so permissions granted to another
EventKit tool do not carry over.

## Calendars

### List Calendars

**Command:**

```bash
eventkitcontrol list calendars
```

**Output:**

```json
{
  "calendars": [
    {
      "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153",
      "title": "Work",
      "type": "event",
      "source": { "id": "SOURCE_ID", "title": "iCloud", "type": "calDAV" },
      "color": "#0088FF",
      "allowsModifications": true
    }
  ],
  "status": "success"
}
```

### Create Calendar

Choose an account source explicitly; eventkitcontrol never guesses an iCloud or local
account:

```bash
eventkitcontrol list sources
eventkitcontrol calendar create --source SOURCE_ID --title "Project X" --color "#FF5500"
```

### Update Calendar

**Command:**

```bash
eventkitcontrol calendar update CALENDAR_ID --title "New Name" --color "#00FF00"
```

### Delete Calendar

**Command:**

```bash
eventkitcontrol calendar delete CALENDAR_ID --dry-run
eventkitcontrol calendar delete CALENDAR_ID --confirm CALENDAR_ID
```

Calendar update and deletion operate on event-only calendars. Reminder lists
are listed separately with `eventkitcontrol list reminder-lists` and are not deletable by
this CLI.

### Aliases

Use friendly names instead of UUIDs. Aliases work anywhere a calendar ID is accepted.

**Set alias:**

```bash
eventkitcontrol alias set work "CA513B39-1659-4359-8FE9-0C2A3DCEF153"
eventkitcontrol alias set personal "4E367C6F-354B-4811-935E-7F25A1BB7D39"
```

Use `--dry-run` to securely load the current config and preview an alias's
before/after value without touching the config file.

**List aliases:**

```bash
eventkitcontrol alias list
```

**Output:**

```json
{
  "aliases": [
    { "name": "groceries", "id": "E30AE972-8F29-40AF-BFB9-E984B98B08AB" },
    { "name": "personal", "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39" },
    { "name": "work", "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153" }
  ],
  "count": 3,
  "configPath": "/Users/you/.eventkitcontrol/config.json",
  "status": "success"
}
```

**Remove alias:**

```bash
eventkitcontrol alias remove work
```

**Usage:**

```bash
# These are equivalent:
eventkitcontrol list events --calendar "CA513B39-1659-4359-8FE9-0C2A3DCEF153" --from "2026-01-01T00:00:00Z" --to "2026-01-31T23:59:59Z"
eventkitcontrol list events --calendar work --from "2026-01-01T00:00:00Z" --to "2026-01-31T23:59:59Z"
```

Aliases are stored in `~/.eventkitcontrol/config.json`. The directory, lock, and config
must be owned by the current user, use private `0700`/`0600` modes, and have no
extended ACLs; unsafe entries are rejected rather than silently trusted.

## Events

### List Events

**Command:**

```bash
eventkitcontrol list events --calendar work --from "2026-01-01T00:00:00Z" --to "2026-01-31T23:59:59Z"
```

To fetch events from multiple calendars in a single call, pass a comma-separated list of IDs or aliases. Each event's source calendar is reported in its `calendar` field, so the merged stream is still distinguishable:

```bash
eventkitcontrol list events --calendar work,personal --from "2026-01-01T00:00:00Z" --to "2026-01-31T23:59:59Z"
```

**Filtering:**

Narrow the result set further with `--search` (case-insensitive substring across title, location, and notes) and `--availability` (one of `busy`, `free`, `tentative`, `unavailable`, `notSupported`). Both filters compose with each other and with the calendar/date selection:

```bash
# Just the standup-related events
eventkitcontrol list events --calendar work --from "$NOWISH" --to "$TOMORROW" --search standup

# Only "busy" events — useful for finding actual blocked-out time
eventkitcontrol list events --calendar work --from "$NOWISH" --to "$TOMORROW" --availability busy

# Combine — standups marked busy
eventkitcontrol list events --calendar work --from "$NOWISH" --to "$TOMORROW" --search standup --availability busy
```

**Output:**

```json
{
  "count": 2,
  "events": [
    {
      "id": "ABC123:DEF456",
      "title": "Team Meeting",
      "calendar": {
        "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153",
        "title": "Work"
      },
      "startDate": "2026-01-15T09:00:00Z",
      "endDate": "2026-01-15T10:00:00Z",
      "location": "Conference Room A",
      "notes": null,
      "allDay": false,
      "hasAlarms": true,
      "hasRecurrenceRules": false,
      "availability": "busy",
      "attendees": []
    }
  ],
  "status": "success"
}
```

### Quick date ranges: `today` / `tomorrow` / `next`

Three top-level shortcuts wrap the most common `list events` queries with a pre-computed local date range. No more `date -u -v+1d` shell prelude (which is BSD-only and breaks on Linux):

```bash
# Events occurring today (local time)
eventkitcontrol today --calendar work

# Events occurring tomorrow
eventkitcontrol tomorrow --calendar work

# The single next upcoming event (looks 90 days ahead by default)
eventkitcontrol next --calendar work

# The next N events
eventkitcontrol next --calendar work --count 5

# Look further out
eventkitcontrol next --calendar work --count 5 --days 365
```

All three accept the same filter / format flags as `list events` (`--search`, `--availability`, `--format`, and comma-separated `--calendar`), so they compose:

```bash
eventkitcontrol today --calendar work,personal --availability busy --format csv
eventkitcontrol next --calendar work --search standup --count 3 --format text
```

`next` returns events sorted by start time ascending and includes events that are currently in progress (their `endDate` is still in the future).

### Show Event

**Command:**

```bash
eventkitcontrol show event EVENT_ID
```

For a recurring event, copy both values from its JSON `selector` object. An ID
alone is deliberately rejected because EventKit otherwise resolves an arbitrary
occurrence:

```bash
eventkitcontrol show event EVENT_ID \
  --occurrence "2026-02-12T18:00:00Z" \
  --expected-start "2026-02-12T18:00:00Z"
```

### Add Event

Basic event:

```bash
eventkitcontrol add event --calendar work --title "Lunch" --start "2026-02-10T12:30:00Z" --end "2026-02-10T13:30:00Z"
```

With location, notes, and alarms:

```bash
eventkitcontrol add event \
  --calendar work \
  --title "Project Review" \
  --start "2026-02-15T14:00:00Z" \
  --end "2026-02-15T15:30:00Z" \
  --location "Building 2, Room 301" \
  --notes "Bring Q1 reports" \
  --alarms "10,60"
```

Recurring event (weekly):

```bash
eventkitcontrol add event \
  --calendar personal \
  --title "Gym" \
  --start "2026-02-12T18:00:00Z" \
  --end "2026-02-12T19:00:00Z" \
  --recurrence-frequency weekly \
  --recurrence-days "mon,wed,fri" \
  --recurrence-end-count 20
```

Every recurrence must choose exactly one end mode:
`--recurrence-end-count`, `--recurrence-end-date`, or `--recurrence-no-end`.

Geocoding is off by default. Opt in only when you want location text sent to
Apple's geocoder:

```bash
eventkitcontrol add event \
  --calendar work \
  --title "Client Site Visit" \
  --start "2026-02-20T14:00:00Z" \
  --end "2026-02-20T16:00:00Z" \
  --location "1 Infinite Loop, Cupertino, CA" \
  --geocode-location
```

**Output:**

```json
{
  "status": "success",
  "message": "Event created successfully",
  "event": {
    "id": "NEW123:EVENT456",
    "title": "Lunch",
    "calendar": {
      "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153",
      "title": "Work"
    },
    "startDate": "2026-02-10T12:30:00Z",
    "endDate": "2026-02-10T13:30:00Z",
    "location": null,
    "notes": null,
    "allDay": false
  }
}
```

### Update Event

All flags are optional — only the fields you pass will be changed:

```bash
eventkitcontrol update event EVENT_ID --title "New title"
```

Date changes are the exception: supply `--start`, `--end`, and
`--all-day true|false` together so the CLI can validate the complete range.
Use `--clear-alarms` for an intentional removal; an empty or malformed
`--alarms` value is rejected without changing existing alarms.
Both `--alarms` and `--clear-alarms` replace every existing EventKit alarm
object. That includes absolute alarms and any custom action, sound/email/
procedure, proximity, or structured-location metadata. A dry run reports the
complete before/after alarm set and this replacement scope before anything is
saved.

Alarm CLI input is expressed in minutes. Event output names EventKit's raw
values explicitly as `relativeAlarmOffsetsSeconds` and `offsetSeconds`, so the
units cannot be mistaken for reusable `--alarms` input.

With multiple fields:

```bash
eventkitcontrol update event EVENT_ID \
  --title "Updated title" \
  --start "2026-02-15T14:00:00Z" \
  --end "2026-02-15T15:30:00Z" \
  --all-day false \
  --location "Building 2, Room 301" \
  --notes "Updated notes" \
  --alarms "10,30" \
  --availability busy \
  --url "https://example.com/meeting"
```

**Output:**

```json
{
  "status": "success",
  "message": "Event updated successfully",
  "event": {
    "id": "ABC123:DEF456",
    "title": "Updated title",
    "calendar": {
      "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153",
      "title": "Work"
    },
    "startDate": "2026-02-15T14:00:00+08:00",
    "endDate": "2026-02-15T15:30:00+08:00",
    "location": "Building 2, Room 301",
    "notes": "Updated notes",
    "allDay": false,
    "hasAlarms": true,
    "hasRecurrenceRules": false
  }
}
```

### Delete Event

**Command:**

```bash
eventkitcontrol delete event EVENT_ID --dry-run
eventkitcontrol delete event EVENT_ID --yes
```

**Output:**

```json
{
  "status": "success",
  "message": "Event 'Team Meeting' deleted successfully",
  "deletedEventID": "ABC123:DEF456"
}
```

## Reminders

### List Reminders

All reminders:

```bash
eventkitcontrol list reminders --list personal
```

Only incomplete:

```bash
eventkitcontrol list reminders --list personal --completed false
```

Only completed:

```bash
eventkitcontrol list reminders --list personal --completed true
```

Substring filter on title and notes:

```bash
eventkitcontrol list reminders --list personal --search milk
```

**Output:**

```json
{
  "count": 2,
  "reminders": [
    {
      "id": "REM123-456-789",
      "title": "Buy groceries",
      "list": {
        "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39",
        "title": "Reminders"
      },
      "dueDate": "2026-01-20T17:00:00Z",
      "completed": false,
      "priority": 0,
      "notes": null
    }
  ],
  "status": "success"
}
```

### Show Reminder

**Command:**

```bash
eventkitcontrol show reminder REMINDER_ID
```

### Add Reminder

Simple reminder:

```bash
eventkitcontrol add reminder --list personal --title "Call dentist"
```

With due date:

```bash
eventkitcontrol add reminder --list personal --title "Submit expense report" --due "2026-01-25T09:00:00Z"
```

With priority and notes (priority: 0=none, 1=high, 5=medium, 9=low):

```bash
eventkitcontrol add reminder \
  --list groceries \
  --title "Buy milk" \
  --due "2026-02-01T12:00:00Z" \
  --priority 1 \
  --notes "Check expiration date"
```

**Output:**

```json
{
  "status": "success",
  "message": "Reminder created successfully",
  "reminder": {
    "id": "NEWREM-123-456",
    "title": "Submit expense report",
    "list": {
      "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39",
      "title": "Reminders"
    },
    "dueDate": "2026-01-25T09:00:00Z",
    "completed": false,
    "priority": 0,
    "notes": null
  }
}
```

### Update Reminder

**Command:**

```bash
eventkitcontrol update reminder REMINDER_ID --title "New title" --due "2026-02-01T09:00:00Z" --priority 1 --notes "Updated notes"
```

All flags are optional — only the fields you pass will be changed:

```bash
# Just change the title
eventkitcontrol update reminder REMINDER_ID --title "Renamed reminder"

# Bump priority and add a due date
eventkitcontrol update reminder REMINDER_ID --priority 1 --due "2026-03-10T09:00:00Z"

# Mark as completed via update (same effect as complete command)
eventkitcontrol update reminder REMINDER_ID --completed true
```

**Output:**

```json
{
  "status": "success",
  "message": "Reminder updated successfully",
  "reminder": {
    "id": "REM123-456-789",
    "title": "New title",
    "list": {
      "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39",
      "title": "Reminders"
    },
    "dueDate": "2026-02-01T09:00:00+08:00",
    "completed": false,
    "priority": 1,
    "notes": "Updated notes"
  }
}
```

### Complete Reminder

**Command:**

```bash
eventkitcontrol complete reminder REMINDER_ID
```

**Output:**

```json
{
  "status": "success",
  "message": "Reminder 'Buy groceries' marked as completed",
  "reminder": {
    "id": "REM123-456-789",
    "title": "Buy groceries",
    "completed": true,
    "completionDate": "2026-01-21T10:30:00Z"
  }
}
```

### Delete Reminder

**Command:**

```bash
eventkitcontrol delete reminder REMINDER_ID --dry-run
eventkitcontrol delete reminder REMINDER_ID --yes
```

## Date Format

Timed date inputs accept strict **ISO 8601** timestamps in these forms. The
entire value is consumed; invalid calendar days, trailing text, and impossible
offsets are rejected:

| Format | Example | Description |
| -------- | --------- | ------------- |
| UTC | `2026-01-15T09:00:00Z` | 9:00 AM UTC |
| Offset with colon | `2026-01-15T09:00:00+10:00` | 9:00 AM AEST (RFC 3339) |
| Compact offset | `2026-01-15T09:00:00+1000` | Same instant, jq-style `%z` form |

Timestamps in **output** are rendered in your local timezone and are always valid input, so values round-trip between commands. The rendering is controlled by `--time-format` on every command:

- `--time-format rfc3339` (default): colon-separated offset, `Z` for UTC — `2026-01-15T20:00:00+11:00`
- `--time-format compact`: no colon, and `+0000` instead of `Z` — `2026-01-15T20:00:00+1100`

`compact` exists because jq's `strptime` understands the `%z` offset form (`+1100`) but not the colon-separated `%:z` form (`+11:00`), so it can post-process eventkitcontrol timestamps directly:

```bash
# "09:00AM Standup" — the next 5 events with 12-hour start times
eventkitcontrol next --calendar work --count 5 --time-format compact |
  jq -r '.events[] | "\(.startDate | strptime("%Y-%m-%dT%H:%M:%S%z") | strftime("%I:%M%p")) \(.title)"'
```

All-day event boundaries use `YYYY-MM-DD` instead. `--end` is the exclusive end
day, matching EventKit. A one-day event on June 3 uses
`--start 2026-06-03 --end 2026-06-04 --all-day`. All-day values are also emitted
date-only.

## Mutation safety and scripting

Every command that changes EventKit or alias configuration accepts `--dry-run`.
Dry runs validate and preview but do not save, delete, geocode, or rewrite the
alias file. Event and reminder deletion additionally require `--yes`; calendar
deletion requires `--confirm` with the exact resolved calendar ID.

Recurring event show/update/delete commands require the `--occurrence` and
`--expected-start` pair shown in list/show output. Supplying the pair for a
non-recurring event is also rejected, preventing stale selectors from targeting
the wrong item. The original occurrence is always emitted as a timestamp—even
when a detached occurrence is currently all-day—so its exact recurring slot is
not lost.

Errors are written to stderr as the selected structured format. Exit statuses
are stable: `0` success, `64` invalid input, `1` operation failure, and `2`
permission denial. CSV output neutralises spreadsheet-formula prefixes, while
text output renders terminal control characters visibly.

## Scripting Examples

### Get calendar ID by name

```bash
CALENDAR_ID=$(eventkitcontrol list calendars | jq -r '.calendars[] | select(.title == "Work") | .id')
echo $CALENDAR_ID
```

### List today's events

```bash
eventkitcontrol today --calendar "$CALENDAR_ID"
```

The `today` / `tomorrow` / `next` subcommands work out the date range locally so you don't have to wrangle `date -v+1d` (which is BSD-only and breaks under Linux), and they accept the same `--search`, `--availability`, and `--format` flags as `list events`:

```bash
# Tomorrow's busy meetings as CSV
eventkitcontrol tomorrow --calendar work --availability busy --format csv

# Next 3 events that mention "standup"
eventkitcontrol next --calendar work --count 3 --search standup
```

`next --days` accepts 1 through 1461 days, keeping EventKit queries and date
arithmetic within a bounded four-year window.
Explicit `list events --from/--to` ranges use the same 1461-day maximum.

### Create event from variables

```bash
TITLE="Sprint Planning"
START="2026-01-20T10:00:00Z"
END="2026-01-20T11:00:00Z"

eventkitcontrol add event \
  --calendar "$CALENDAR_ID" \
  --title "$TITLE" \
  --start "$START" \
  --end "$END"
```

### Count incomplete reminders

```bash
eventkitcontrol list reminders --list "$LIST_ID" --completed false | jq '.count'
```

### Export events to CSV

Use the built-in `--format csv` flag — no jq pipeline required. The CSV header is the union of every field across the returned events, so new fields like `availability` and `attendees` are picked up automatically as they're added:

```bash
eventkitcontrol list events \
  --calendar "$CALENDAR_ID" \
  --from "2026-01-01T00:00:00Z" \
  --to "2026-12-31T23:59:59Z" \
  --format csv \
  > events.csv
```

Nested objects flatten to dot-notated columns (e.g., `calendar.id`, `calendar.title`), and nested arrays (like `attendees`) become a single JSON-encoded cell.

### Human-readable plain text

`--format text` emits one `key: value` line per field, with a blank line between items — handy for `grep`, eyeballing, or quick `head`/`tail` checks:

```bash
eventkitcontrol list events --calendar work --from "$TODAY" --to "$TOMORROW" --format text
```

## Error Handling

Errors are written to stderr in the selected `--format` (JSON by default).
JSON errors include a stable code and the corresponding process exit status:

```json
{
  "status": "error",
  "error": "Calendar not found with ID: invalid-id",
  "code": "operation_failed",
  "exitCode": 1
}
```

Common errors:

- `Permission denied`: Grant access in System Settings → Privacy & Security → Calendars/Reminders
- `Calendar not found`: Check calendar ID with `eventkitcontrol list calendars`
- `Invalid date format`: Use ISO 8601 (e.g., `2026-01-15T09:00:00Z`, `+10:00`, or `+1000` offsets — see [Date Format](#date-format))

Exit codes: `0` success, `1` failure, `2` permission denied, `64` invalid usage (bad flags/values).

## Help

```bash
eventkitcontrol --help
eventkitcontrol list --help
eventkitcontrol add event --help
```

## License

[MIT](LICENSE)

## Contributing

Pull requests welcome.

## Project lineage

eventkitcontrol began as a fork of
[ekctl](https://github.com/schappim/ekctl), originally created by Marcus Schappi.
It now has its own command, configuration, bundle identity, and distribution and
does not maintain binary or command compatibility with upstream.
