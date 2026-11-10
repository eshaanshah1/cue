# Cue

A menu bar calendar for macOS. Shows your next meeting, gets you into the call in one click, and puts a large reminder on screen when a meeting starts.

## Build and run

```sh
./build.sh          # → build/Cue.app (~2 MB with the icon, ad-hoc signed)
open build/Cue.app
```

Cue reads Google Calendar directly (read-only). Click the menu bar item and choose **Sign in with Google**. The OAuth client lives in `google-oauth.json`, which is git-ignored and copied into the app by `build.sh`. The sign-in token is kept in the Keychain, and Cue polls Google every three minutes, plus on wake and when you open the popover.

Sign-in asks for everything at once: `calendar.events` (add, edit, move, reply), `calendar.readonly`, and `directory.readonly` (your coworkers). Sign-ins from an older Cue get asked once when the popover opens, and again whenever an action needs write access. Coworkers' availability comes from Google's free/busy lookup, which needs nothing extra. People suggestions are the people you've met over the past 60 days, then everyone in your Workspace directory. The directory needs the **People API** enabled for the OAuth client's Google Cloud project; without it Cue falls back to recent people only.

Drag a meeting along the ribbon to move it. It snaps to quarter hours. Up to four guests get a lane each under the ribbon, and five or more share one strip that's green where everyone is free. Let go to confirm: your own meetings move and Google emails the guests. For someone else's meeting the Calendar API has no "propose a new time", so Cue replies Maybe with the new time as the note, and Google emails that to the organiser. Esc puts it back.

To use macOS Calendar instead, pick it from the gear menu. Cue then reads whatever is synced under System Settings → Internet Accounts.

Because the build is ad-hoc signed, macOS may ask again for Keychain or calendar access after a rebuild. Choose Always Allow.

While the Google Cloud app is in Testing, Google signs you out every 7 days. Publishing it stops that.

Install with `ditto build/Cue.app /Applications/Cue.app`.

## Demo mode

Runs on the mockups' meetings at a pretend time and never opens real links.

```sh
open -n build/Cue.app --args --demo 10:18 --show popover   # popover
open -n build/Cue.app --args --demo 10:29:10               # overlay fires at 10:29
open -n build/Cue.app --args --demo 10:37 --show card      # minimized card
.build/debug/Cue --demo --snapshot snaps                   # render every surface to PNGs
```

## Layout

- `CalendarStore` loads today and tomorrow from Google (`GoogleAuth`, `GoogleCalendar`) or from EventKit.
- `AppModel` runs a single timer aimed at the next minute boundary and drives the alert flow: overlay → minimized card → closed. Joining a call closes it.
- `Windows.swift` holds the AppKit panels (popover, 80% overlay, floating card) and the menu bar item.
- `Move.swift` handles dragging a meeting on the ribbon: the guests' lanes, conflicts, and Move or Propose.
- `Compose.swift` handles adding events: text parsing, free slots, and the per-person lanes. `Detail.swift` holds the details, edit and permission screens.
- `Views.swift` holds the rest of the SwiftUI content. Per-second updates happen only inside visible countdowns.
- `mockups/` has the design boards these screens were built from.
