# Cue

A menu bar calendar for macOS. Shows your next meeting, gets you into the call in one click, and puts a large reminder on screen when a meeting starts.

## Build and run

```sh
./build.sh          # → build/Cue.app (~2 MB with the icon, ad-hoc signed)
open build/Cue.app
```

Cue reads Google Calendar directly (read-only). Click the menu bar item and choose **Sign in with Google**. The OAuth client lives in `google-oauth.json`, which is git-ignored and copied into the app by `build.sh`. The sign-in token is kept in the Keychain, and Cue polls Google every three minutes, plus on wake and when you open the popover.

Adding, editing, replying and find-a-time need the `calendar.events` permission. Cue asks you to sign in again the first time you use one of them. Find-a-time uses Google's free/busy lookup, and people suggestions come from your meetings over the past 60 days.

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
- `Compose.swift` handles adding events: text parsing, free slots, and the per-person lanes. `Detail.swift` holds the details, edit and permission screens.
- `Views.swift` holds the rest of the SwiftUI content. Per-second updates happen only inside visible countdowns.
- `mockups/` has the design boards these screens were built from.
