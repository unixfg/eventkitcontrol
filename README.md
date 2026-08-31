# eventkitcontrol

[![CI](https://github.com/unixfg/eventkitcontrol/actions/workflows/ci.yml/badge.svg)](https://github.com/unixfg/eventkitcontrol/actions/workflows/ci.yml)

eventkitcontrol lets you list and manage Apple Calendar events and Reminders
from the macOS command line. You can preview every change before saving it;
event, reminder, and calendar deletions require confirmation. Output defaults
to JSON for scripts, with CSV and plain text also available.

See the [changelog](CHANGELOG.md) for the complete first-release scope and the
reasoning behind intentional compatibility decisions.

## Features

- List, create, update, and delete calendar events
- List, create, update, complete, and delete reminders
- Preview every change with `--dry-run`; event, reminder, and calendar
  deletions require explicit confirmation
- Update or delete one recurring occurrence without accidentally targeting a
  different one
- Quick date-range shortcuts: `today`, `tomorrow`, and `next`
- Search and filter (`--search`, `--availability busy`) without piping through jq
- Calendar and reminder-list aliases (use friendly names instead of UUIDs)
- JSON, CSV, or plain-text output (`--format json|csv|text`)
- RFC 3339 or jq-friendly compact timestamps (`--time-format rfc3339|compact`)
- Requests Calendar or Reminders permission only when a command needs it
- Uses Apple's documented EventKit APIs
- Support for iCloud, Exchange, and local calendars
- Signed and Apple-notarized Apple Silicon `.pkg` installer with no installer
  scripts

## Requirements

- Apple Silicon Mac
- macOS 14.0 (Sonoma) or later
- Building from source additionally requires Swift 6 from Xcode 26 or later.
  Use a full Xcode installation; prebuilt packages have no build-time
  requirements.

## Installation

### Signed package

Published releases provide a signed, Apple-notarized `.pkg` for Apple Silicon
Macs. macOS can verify it even when offline. The installer stops before making
changes on Intel Macs or macOS older than 14. Replace the tag below with the
release you want:

```bash
TAG=v1.0.2
PACKAGE="eventkitcontrol-${TAG}-macos-arm64.pkg"
curl -fLO "https://github.com/unixfg/eventkitcontrol/releases/download/${TAG}/${PACKAGE}"
curl -fLO "https://github.com/unixfg/eventkitcontrol/releases/download/${TAG}/${PACKAGE}.sha256"
shasum -a 256 -c "${PACKAGE}.sha256"
sudo installer -pkg "$PACKAGE" -target /
eventkitcontrol --version
```

For the familiar macOS install flow, stop after the checksum succeeds and
double-click the `.pkg` in Finder (or run `open "$PACKAGE"`). Apple Installer
will show the destination and authorization steps; the `sudo installer`
command above is the scriptable equivalent.

The installer puts `eventkitcontrol` at `/usr/local/bin/eventkitcontrol`. It
contains no installer scripts and does not install the original project's
command name.

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

The script builds an Apple Silicon executable using the dependency versions
recorded in the repository. It signs the local build so macOS can request
Calendar and Reminders access, checks the result, removes temporary build files,
and prints the executable's path under `.build/eventkitcontrol-artifact.*`. It
does not install anything or create a release package. Successful `main` CI runs
also offer temporary test builds; signed tagged packages remain the supported
way to install a release.

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
      "allowsModifications": true,
      "immutable": false,
      "allowedEntityTypes": 1
    }
  ],
  "count": 1,
  "status": "success"
}
```

### List Reminder Lists

Reminder lists are deliberately discovered separately so this command requests
only Reminders access:

```bash
eventkitcontrol list reminder-lists
```

The output uses the same calendar-object fields as `list calendars`, under the
`reminderLists` key with `type: "reminder"`. Use a returned ID directly or give
it an alias:

```json
{
  "count": 1,
  "reminderLists": [
    {
      "id": "REMINDER-LIST-ID",
      "title": "Groceries",
      "type": "reminder",
      "source": { "id": "SOURCE_ID", "title": "iCloud", "type": "calDAV" },
      "color": "#FF9500",
      "allowsModifications": true,
      "immutable": false,
      "allowedEntityTypes": 2
    }
  ],
  "status": "success"
}
```

```bash
eventkitcontrol alias set groceries REMINDER_LIST_ID
```

### List Sources

List the account sources available to EventKit for an explicit
event-calendar creation attempt. A source can still reject creation because of
its account type, permissions, or server policy:

```bash
eventkitcontrol list sources
```

```json
{
  "count": 1,
  "sources": [
    {
      "id": "SOURCE_ID",
      "title": "iCloud",
      "type": "calDAV",
      "eventCalendarCount": 4
    }
  ],
  "status": "success"
}
```

### Create Calendar

Choose an account source explicitly; eventkitcontrol never guesses an iCloud or local
account:

```bash
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
are listed separately and are not deletable by this CLI.

### Aliases

Use friendly names instead of UUIDs. Aliases work anywhere an event-calendar
or reminder-list ID is accepted.

**Set alias:**

```bash
eventkitcontrol alias set work "CA513B39-1659-4359-8FE9-0C2A3DCEF153"
eventkitcontrol alias set personal "EVENT-CALENDAR-ID"
eventkitcontrol alias set groceries "REMINDER-LIST-ID"
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
    { "name": "personal", "id": "PERSONAL-EVENT-CALENDAR-ID" },
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

Aliases are stored in `~/.eventkitcontrol/config.json`. The directory, lock,
and config must be owned by the current user and have no extended ACLs, unsafe
links, or unexpected file types. At this canonical path, existing POSIX modes
are repaired to private `0700`/`0600` values before use; override directories
must already be private. Other unsafe entries are rejected rather than silently
trusted.

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
FROM="2026-01-15T00:00:00Z"
TO="2026-01-16T00:00:00Z"

# Just the standup-related events
eventkitcontrol list events --calendar work --from "$FROM" --to "$TO" --search standup

# Only "busy" events — useful for finding actual blocked-out time
eventkitcontrol list events --calendar work --from "$FROM" --to "$TO" --availability busy

# Combine — standups marked busy
eventkitcontrol list events --calendar work --from "$FROM" --to "$TO" --search standup --availability busy
```

**Example output (abridged):**

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

Every event object also carries `relativeAlarmOffsetsSeconds`, detailed
`alarms`, detailed `recurrenceRules`, a recurring-occurrence `selector` or
`null`, `detached`, `availability`, and `attendees`. `url` is present when the
event has one. The same event object is used by list, show, add, update, and
dry-run output.

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

`--alarms` takes comma-separated minutes from the event start. `10` and `-10`
both mean 10 minutes before the event; write `+10` to mean 10 minutes after:

| Input | Meaning | EventKit offset |
| --- | --- | --- |
| `10` | 10 minutes before | `-600` seconds |
| `-10` | 10 minutes before | `-600` seconds |
| `+10` | 10 minutes after | `600` seconds |

The command rejects the whole list if any value is missing, invalid, repeated,
or more than 365 days from the event. Up to 64 alarms are allowed, and nothing
is changed when the list is rejected.

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

Recurrence options that take comma-separated lists reject invalid or duplicate
choices, even when the same choice is written differently, such as
`mon,monday`. `--recurrence-interval` is valid for every frequency. Beyond
that shared interval and the required end mode, these options are available:

| Frequency | Options available for that frequency |
| --- | --- |
| `daily` | none |
| `weekly` | `--recurrence-days` |
| `monthly` | `--recurrence-days` or `--recurrence-days-of-month`, plus optional `--recurrence-set-positions` |
| `yearly` | `--recurrence-days`, `--recurrence-months`, `--recurrence-weeks-of-year`, `--recurrence-days-of-year`, and optional `--recurrence-set-positions` |

Monthly and yearly weekdays may include a position such as `1mon` for the first
Monday or `-1fri` for the last Friday.
`--recurrence-months` accepts names or `1` through `12`. Month days, year
weeks, year days, and set positions accept positive or negative numbers, but
not zero. Positive values count forward and negative values count backward, so
`-1` means “last.” Their largest allowed absolute values are `31`, `53`, `366`,
and `366`, respectively. Set positions require another compatible monthly or
yearly option. Incompatible combinations fail before requesting access.

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

**Example output (abridged):**

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

**Warning:** changing or clearing alarms replaces the event's entire alarm
list. This discards any fixed-date or location-based alarms, custom sounds,
email actions, or other alarm details that the command cannot recreate.
Preview the operation with `--dry-run` first; the preview shows the complete
before-and-after alarm lists and explains what would be lost.

Changing `--location` can also remove coordinates and other map information
stored by Calendar. Without `--geocode-location`, the text changes and the old
map information is cleared. With the flag, new map information replaces it only
after lookup succeeds; a failed lookup leaves the event unchanged. A dry run
reports this under `changes.structuredLocation`.

JSON reports relative alarm offsets in seconds under
`relativeAlarmOffsetsSeconds` and `offsetSeconds`, while `--alarms` accepts
minutes. Do not paste those numbers directly back into `--alarms`. Each alarm
entry also says whether it is relative or fixed to a date and whether it
contains custom action, proximity, location, email, or sound information.

For recurring events, `recurrenceRules` describes the stored rule and
`selector` identifies one occurrence. Copy `selector.occurrenceDate` to
`--occurrence` and `selector.expectedStart` to `--expected-start` unchanged.

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

**Example output (abridged):**

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

**Example output (abridged):**

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
eventkitcontrol list reminders --list groceries
```

Only incomplete:

```bash
eventkitcontrol list reminders --list groceries --completed false
```

Only completed:

```bash
eventkitcontrol list reminders --list groceries --completed true
```

Substring filter on title and notes:

```bash
eventkitcontrol list reminders --list groceries --search milk
```

**Example output (abridged):**

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
eventkitcontrol add reminder --list groceries --title "Call dentist"
```

With due date:

```bash
eventkitcontrol add reminder --list groceries --title "Submit expense report" --due "2026-01-25T09:00:00Z"
```

Every integer priority from `0` through `9` is accepted. EventKit convention
uses `0` for none, `1` for high, `5` for medium, and `9` for low; intermediate
values preserve their exact EventKit priority.

With priority and notes:

```bash
eventkitcontrol add reminder \
  --list groceries \
  --title "Buy milk" \
  --due "2026-02-01T12:00:00Z" \
  --priority 1 \
  --notes "Check expiration date"
```

**Example output (abridged):**

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

**Example output (abridged):**

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

**Example output (abridged):**

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
| Fractional seconds | `2026-01-15T09:00:00.123456789Z` | One through nine fractional digits |

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

## Previewing and confirming changes

Every command that changes calendar, reminder, or alias data supports
`--dry-run`. It performs the same checks and shows what would change, but does
not save or delete anything, send an address for geocoding, or change the alias
file. Real event and reminder deletions require `--yes`; calendar deletion
requires `--confirm` with the actual calendar ID, not an alias.

Every successful change includes `dryRun` and `applied`, so scripts can tell a
preview from a saved change. Update previews also include a field-by-field
`changes` object. For example, this command:

```bash
eventkitcontrol update event EVENT_ID --title "New title" --dry-run
```

returns the complete current event snapshot alongside the proposed change:

```json
{
  "applied": false,
  "changes": {
    "title": { "after": "New title", "before": "Old title" }
  },
  "dryRun": true,
  "event": {
    "alarms": [],
    "allDay": false,
    "attendees": [],
    "availability": "busy",
    "calendar": { "id": "CALENDAR_ID", "title": "Work" },
    "detached": false,
    "endDate": "2026-02-15T15:00:00Z",
    "hasAlarms": false,
    "hasRecurrenceRules": false,
    "id": "EVENT_ID",
    "location": null,
    "notes": null,
    "recurrenceRules": [],
    "relativeAlarmOffsetsSeconds": [],
    "selector": null,
    "startDate": "2026-02-15T14:00:00Z",
    "title": "Old title"
  },
  "geocodingWouldRun": false,
  "message": "Event update validated; no event was saved.",
  "status": "success"
}
```

For an alarm update, `changes.alarms` contains the complete old and proposed
alarm lists, their counts, and a warning about details the command cannot
recreate.

For a recurring event, copy both values from its `selector` object into
`--occurrence` and `--expected-start`. If either value is missing or no longer
matches, the command stops; list the event again to get fresh values. Supplying
the pair for a non-recurring event is also rejected, which prevents an old
selector from targeting the wrong item.

For scripts, errors are written to the standard error stream in the selected
format. Exit statuses are stable: `0` means success, `64` invalid input, `1` an
operation failure, and `2` permission denial. CSV output prevents calendar text
from becoming a spreadsheet formula, while plain-text output displays terminal
control characters instead of executing them.

## Current limitations

- Travel time is not shown or changed because Apple provides no public EventKit
  API for it. The [changelog](CHANGELOG.md) explains why the earlier option was
  removed rather than kept as an unreliable promise.
- The command can create alarms before or after an event. It can show fixed-date
  alarms and custom details, but cannot recreate them if you replace the alarm
  list.
- Recurrence rules can be created but not edited. Updates and deletions affect
  one explicitly selected occurrence, not the whole series or all future
  occurrences.
- Events and reminders cannot be moved to another calendar or list. Attendees
  and reminder URLs are read-only.
- Event URLs can be set but not cleared, and reminder due dates cannot be
  cleared.
- Reminder lists can be listed and used, but not created, changed, or deleted.

## Scripting Examples

### Get calendar ID by name

```bash
CALENDAR_ID=$(eventkitcontrol list calendars | jq -r '.calendars[] | select(.title == "Work") | .id')
echo "$CALENDAR_ID"
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
eventkitcontrol list reminders --list groceries --completed false | jq '.count'
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
eventkitcontrol today --calendar work --format text
```

## Error Handling

Errors are written to stderr in the selected `--format` (JSON by default).
JSON errors include a stable code and the corresponding process exit status:

```json
{
  "status": "error",
  "error": "Event calendar not found with ID: invalid-id",
  "code": "operation_failed",
  "exitCode": 1
}
```

Common errors:

- `Permission denied`: Grant access in System Settings → Privacy & Security → Calendars/Reminders
- `Event calendar not found`: Check the calendar ID with `eventkitcontrol list calendars`
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

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development checks, focused
commit guidance, and the process for carefully reimplementing a safety fix for
the original project without exporting this fork's identity or product policy.

## Project lineage

eventkitcontrol began from
[an earlier macOS EventKit CLI codebase at this immutable fork point](https://github.com/unixfg/eventkitcontrol/commit/79a7c86124c04a93180ce2aeb281a5e3e483f88a),
originally created by [Marcus Schappi](https://github.com/schappim). It now has
its own command, configuration, bundle identity, and distribution and does not
maintain binary, command, output, or configuration compatibility with the
original project.

eventkitcontrol is an independent project and is not affiliated with or
endorsed by Apple Inc. EventKit and macOS are referenced only to describe the
Apple technologies with which the tool interoperates.
