# Advanced eventkitcontrol operations

Read the section relevant to the task. The discovery, authorization, preview,
date, and result-handling rules in `SKILL.md` also apply here. Set the ID and
selector variables below from actual query results.

## Create recurring events

Only `add event` accepts recurrence options. Supply `--recurrence-frequency`
with `daily`, `weekly`, `monthly`, or `yearly`, and **exactly one** end mode:

- `--recurrence-end-count N`: a positive number of occurrences.
- `--recurrence-end-date VALUE`: a strict timestamp for timed events or
  `YYYY-MM-DD` for all-day events.
- `--recurrence-no-end`: an explicitly unbounded recurrence.

All frequencies accept a positive `--recurrence-interval`; the default is 1.
Choose the recurrence end from the user's request rather than silently making
the series unbounded.

```bash
eventkitcontrol add event --calendar "$CALENDAR_ID" --title "Team check-in" \
  --start "2026-10-05T09:00:00-04:00" --end "2026-10-05T09:30:00-04:00" \
  --recurrence-frequency weekly --recurrence-days "mon,wed,fri" \
  --recurrence-end-count 12 --dry-run
```

| Frequency | Compatible selection options |
| --- | --- |
| `daily` | None beyond interval and end mode. |
| `weekly` | `--recurrence-days` with plain weekdays. |
| `monthly` | `--recurrence-days` **or** `--recurrence-days-of-month`; optional `--recurrence-set-positions` with a selector. |
| `yearly` | `--recurrence-days`, `--recurrence-months`, `--recurrence-weeks-of-year`, `--recurrence-days-of-year`; optional `--recurrence-set-positions` with a selector. |

Lists are comma-separated and reject empty, invalid, or duplicate choices,
including equivalent forms such as `mon,monday`. Monthly and yearly weekdays
can have ordinals, such as `1mon` or `-1fri`. Months accept names or 1–12.
Signed month days, year weeks, year days, and set positions exclude zero and
have maximum absolute values of 31, 53, 366, and 366 respectively; `-1` means
last. Check `eventkitcontrol add event --help` for the installed flag set.

To change or delete an existing occurrence, use the selector pair in `SKILL.md`.
There is no recurrence-rule update or whole-series mutation command.

## Alarms and locations

`--alarms` accepts comma-separated **minutes** relative to the event start:

| Input | Meaning | Output offset in seconds |
| --- | --- | --- |
| `10` or `-10` | Ten minutes before | `-600` |
| `+10` | Ten minutes after | `600` |

Use, for example, `--alarms "10,60,+5"`. When a value starts with a minus sign,
use the equals form, such as `--alarms=-10`, to avoid option-parser ambiguity.
Values must be unique after normalization, so `10,-10` is invalid. At most 64
alarms are allowed, each at most 365 days from the event. Any invalid entry
rejects the complete list. JSON `relativeAlarmOffsetsSeconds` and alarm
`offsetSeconds` values are **seconds**, not directly reusable CLI values.

Updating `--alarms` replaces the entire list; `--clear-alarms` explicitly removes
it. These flags are mutually exclusive. Both can discard fixed-date alarms,
location triggers, custom sounds, email actions, and other details the CLI
cannot recreate. Inspect the current `alarms` and the preview's `changes.alarms`
before applying an edit. Do not send an empty alarm list to mean "leave alone."

```bash
eventkitcontrol update event "$EVENT_ID" --alarms "10,30" --dry-run
eventkitcontrol update event "$EVENT_ID" --clear-alarms --dry-run
```

Include the occurrence selector on these commands when the event is recurring.

`--location` ordinarily stores text without geocoding. On an update, changing
that text clears existing structured map information; the preview describes
this in `changes.structuredLocation`. `--geocode-location` requires a nonempty
`--location`, sends the text to Apple's geocoder, and replaces the map data only
after a successful lookup. Failed geocoding leaves the event unsaved. Enable it
only when the request authorizes that lookup. A dry run does not send the
address; it reports `geocodingWouldRun`.

## Event calendars

Discover the exact account source before creation:

```bash
eventkitcontrol list sources
eventkitcontrol calendar create --source "$SOURCE_ID" \
  --title "Project X" --color "#FF5500" --dry-run
eventkitcontrol calendar update "$CALENDAR_ID" \
  --title "Project archive" --color "#0088FF" --dry-run
```

Set `SOURCE_ID` from the chosen entry in `sources`. Creation always requires an
explicit source; listing a source does not guarantee its account permits
calendar creation. Colors use exactly `#RRGGBB`. Calendar update and deletion
apply only to event calendars; check `allowsModifications` and `immutable`.

Deleting a calendar also removes its contained events, so make sure the user's
request covers that calendar and scope. Preview first, then use the **resolved
ID**, never an alias, as the confirmation value:

```bash
eventkitcontrol calendar delete "$CALENDAR_ID" --dry-run
eventkitcontrol calendar delete "$CALENDAR_ID" --confirm "$CALENDAR_ID"
```

The positional calendar argument can be an alias, but `--confirm` must still be
the actual ID. `--yes` is not the calendar-deletion confirmation mechanism.

## Local aliases

Aliases map friendly names to event-calendar or reminder-list IDs. They do not
rename or delete the underlying EventKit objects, and do not alias individual
events or reminders. Discover the target first; alias storage does not validate
that the ID exists in EventKit.

```bash
eventkitcontrol alias set work "$CALENDAR_ID" --dry-run
eventkitcontrol alias set groceries "$REMINDER_LIST_ID" --dry-run
eventkitcontrol alias list
eventkitcontrol alias remove work --dry-run
```

Apply a requested alias change by removing `--dry-run`. Prefer these commands
over hand-editing `~/.eventkitcontrol/config.json`. Config validation rejects
unsafe ownership, links, file types, and extended ACLs. The canonical config
path repairs POSIX modes to private directory/file permissions of 0700/0600
when needed; override directories must already be private.

`EVENTKITCONTROL_CONFIG_DIR` is an optional narrowly scoped absolute directory
for isolated alias configuration. It does **not** isolate Calendar or Reminders
data: EventKit commands still use the current macOS user's real accounts.
