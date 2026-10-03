# Stress test — 2026-10-03

*Passes over the same build line. Phase A drove a virtual iPhone
(roothide bootstrap, arm64e, a Release `.deb`) and the daemon underneath
it; phase B drove the Mac Catalyst app (Debug) and its launch agent inside
a macOS virtual machine on an Apple silicon Mac; phase C, an iPad, was a
separate run. The helpers live in
`Scripts/stress/` (`procstat`, `sessions-limit.sh`, `flood.sh`,
`churn.sh`, `mac-pointer.swift`). Every bug found is fixed in its own
commit, listed at the end of each phase.*

## How things were measured

- **Main-thread stalls.** An Accessibility round trip — an attribute read
  the app answers on its main run loop — sampled every 100 ms while the
  scenario ran. A round trip over 250 ms counts as a hang. On the phone
  the probe was the guest agent's `ui.element_at`; on the Mac, an
  `AXFocusedWindow`/`AXTitle` read from outside the app.
- **Memory.** `procstat` (phys footprint and resident size) for the app,
  `ighostvtd` and `ighostvtd-io`. launchd's jetsam limit for `ighostvtd`
  on the device is 6 MB; that is the number the proxy is held to.
- **Correctness.** `ighostvt-cli list` / `capture` for what the daemon
  holds, the app's journal for why each tab closed, byte counts (`wc -c`)
  for what a paste delivered.

## Phase A — virtual iPhone and the daemon

### Bugs found

| # | Bug | Evidence | Fix |
|---|---|---|---|
| 1 | Session ids restarted at 1 in every `ighostvtd-io`, so after an io crash a tab's kept id attached to *someone else's* session | `kill -9` io, then `ighostvt-cli new` 40 ms later: the CLI's `sleep` session (id 1) came up attached in a tab; the other tabs spent 2 s retrying `sessionBusy` | `545db06` — ids come from a block counter beside the daemon log that only grows. On the phone the CLI session got 65 and stayed unattached; the tabs got 66–69 at once |
| 2 | **io leak:** the replay buffer was trimmed with `Data.removeFirst`, whose storage kept every byte ever printed | four flooding tabs: io footprint +24 MB/s, 1.1 GB after 45 s, not freed after ^C | `721a271` — trim in batches (keep the newest 256 KiB once the buffer reaches twice that). Harness: 121 MiB growth → 0 for a 128 MiB flood; phone: io flat at 1.6 MB for 60 s of flood |
| 3 | The io link's outbound buffer kept its written prefix until a *full* drain, which the pause/resume hysteresis never allows under a steady flood (the same code runs in the proxy) | harness: 262 MB held for 256 MiB pushed through a backlog that never empties | `972a0e1` — compact once the dead prefix outweighs the live bytes. Harness: 262 MB → 1 MB |
| 4 | A paste refused part-way could deliver its tail after a hole, silently | 768 KB paste into a program not reading: the first 512 KiB chunk refused as `inputBacklog`, the 256 KB tail accepted | `933cecd` — every chunk of a paste carries a paste id; io refuses the rest of a paste once one chunk was refused; the app says "Paste truncated: the program is not reading its input." Phone: five whole pastes delivered 3,932,160 B, the sixth refused whole, notice shown |
| 5 | (test only) malformed session attributes | — | `00e8a44` — harness: a ½ MiB value, a nested dictionary, a non-dictionary, and 600 more refused, 1.4 MiB growth, attributes untouched |

### Scenarios and numbers

**Daemon kills.** `kill -9` of the proxy with four tabs: every tab survived
and reconnected in about a second; the sessions themselves are gone (io
exits with its link), so each tab got a fresh shell under the old screen and
"[iGhostVT] Connection lost. Reconnecting…". `kill -9` of io: the same, as
designed. A kill storm (io killed seven times 0.2–2.5 s apart, then the
proxy twice) used up to four of a tab's five reconnect attempts; all three
tabs survived. An outage longer than about five seconds would leave a tab on
the "Unable to reconnect" card, whose Retry works. Every tab close in the
journals had a recorded reason (30 context menu, 58 session ended, 1 status
card); none came from a reconnect.

**64 sessions.** `sessions-limit.sh` held 64; the 65th was refused ("You
already have 64 terminals open"). `ighostvtd` 1.6 MB footprint / 3.6 MB
resident, io 1.7–1.9 MB. The app with 64 tabs: switcher (64 cards, scrolls to
the end), ⋯ menu and title capsule all usable; New Tab at the limit shows the
status card with Close and Retry.

**Flood with UI.** Four tabs running `yes` / `base64 /dev/urandom`: app
about 230 % CPU, io 60 %, proxy 55 %. Round trips (min / median / max, ms):
idle 57 / 59 / 122; flood 63 / 69 / 96; flood while tapping ⋯, Lock Tab,
Lock Keyboard and the switcher 63 / 74 / 103 (80 samples). No stall over
250 ms. App footprint 218 → 312 MB during the flood, 137 MB after ^C.

**Megabyte paste.** 768 KB pastes (the guest caps a clipboard at roughly
512 KB–1 MB) through ⌘V and paste protection's Allow into `cat > file`:
3,145,728 B = 4 × 786,432 exactly. Into a program not reading, io holds at
most 4 MiB of pending input (footprint 5.7 MB, back to 1.6 MB after) and
refuses the rest — which is where bug 4 showed.

**Churn.** CLI: 100 sequential plus 10 × 50 parallel open/kill — 0
failures, 0 zombies, session count back to 7, proxy 1.58 MB, io 1.66 MB.
App: 30 × (New Tab, ⋯ ▸ Close Tab) — all 30 closes logged as "context
menu", sessions back to 7, 0 zombies, footprint 340 → 317 MB.

### Open finding: about 16 MB per occluded surface

With 64 tabs the app's footprint is about **1.0 GB** — roughly 16 MB a tab —
and it is the same on a cold launch that restores 64 tabs nobody has looked
at yet, with no preview images taken. It is the ghostty surfaces: each keeps
its renderer's IOSurfaces at full-screen pixel size while it is occluded.
The footprint does come back (64 → 6 tabs: 1.06 GB → 166 MB). The app keeps
every pane mounted on purpose: unmounting one would free the memory but lose
its grid and scrollback beyond the daemon's 256 KiB replay. The fix belongs
in libghostty-spm — release an occluded surface's IOSurfaces and recreate
them when it shows again — and is not made here.

## Phase B — Mac

Build: the tree at `c66e006` (and, for the stress runs, the fixes listed
below), Debug, staged into `/Applications` with the helper inside as
`package-mac.sh` does. Input came from synthetic pointer and key events
(`Scripts/stress/mac-pointer.swift`); the hang probe was the Accessibility
round trip described above. The machine had macOS's Keyboard Navigation
setting on, which turned out to matter (below).

### Features checked

- **Locks survive the app (step 4).** Interaction-lock a tab from its
  context menu, `kill -9` the app, relaunch: the tab comes back locked, and
  `ighostvt-cli list` shows `interaction` in LOCK. Unlock, kill, relaunch:
  unlocked, LOCK `-`.
- **Move to New Window (step 5).** After `seq 1 50`, the context menu's
  Move to New Window opens a window showing the same output; `echo ok` runs
  there; the tab is gone from the source window. A locked tab keeps its lock
  when moved. A sidebar row dragged outside the window opens nothing on
  the Mac — the drop beside a window is an iPadOS behaviour — so there the
  menu is the way, as AGENTS.md says.
- **Switcher bar (3b).** The bottom bar sits 16 pt above the window's
  bottom edge with the same inset at the sides; it looks right.
- **Paste notice (fix 4).** Not confirmed on the Mac. Two things got in the
  way: macOS `base64` writes one line, and a canonical-mode tty drops a line
  past about 1 KB (the session then swallows ^C and ^D until it is killed —
  kernel behaviour, not ours); and the virtual machine's clipboard is
  synced with its host, which replaced the test data between `pbcopy` and
  ⌘V. Phase A verified the notice and the byte counts.

### Bugs found and fixed

| Bug | Fix |
|---|---|
| `make test` wrote its session-id counter into the user's real `~/Library/Logs/ighostvtd.session-ids` on the host | `04ce3b7` — `IGHOSTVT_SESSION_ID_STORE`, set only by `make harness`, names a file in the harness's temp directory |
| `make test` wrote harness crashes and respawns into the user's real `~/Library/Logs/ighostvtd.log`, which the app's log viewer shows | `c66e006` — `IGHOSTVT_DAEMON_LOG`, set only by `make harness` |
| With keyboard navigation on, every terminal sat in a grey (accent-tinted when key) focus ring | `336f2e2` — `focusEffect = nil` on the terminal view |
| Switcher pictures of a landscape surface (every Mac window) were cropped on both sides, showing the middle of each line | `a60fe9e` — anchored top-leading. Not a regression: the same at `67b85cb`, there since the pictures came in (`ade4d96`) |
| The lock docs promised that the interaction lock "closes every input path"; with keyboard navigation on, a locked tab still takes typed keys and ⌘V | `bbba8e9` — docs only. The locks are for touch; hardware keys, paste and drops are allowed by design |

### Stress numbers

**Flood with UI.** Three tabs flooding (`yes`, `base64 /dev/urandom`, an
OSC 2 title loop) while, three times over: ⌃Tab ×3, the ⋯ menu opened and
dismissed, a chip's context menu opened and dismissed, a chip dragged,
the sidebar toggled twice, the window resized down and back. CPU: app
~131 %, io ~82 %, proxy ~69 %. Round trips (683 samples): median 0.3 ms,
p95 23 ms, max 600 ms, **6 over 250 ms**. The same operations with no flood
(677 samples): max 483 ms, **4 over 250 ms** — the stalls come with the
operations (most likely the resizes and sidebar toggles, which rebuild
the surfaces' size), not with the output. Footprint during the flood:
app 471–479 MB with 7 tabs, io 5.8–6.3 MB, proxy 3.5–4.1 MB.

**Daemon kills.** `kill -9` of `ighostvtd-io` during the flood: all seven
tabs reconnected with fresh shells, ids 129–135 — past every id the dead io
had issued. `kill -9` of `ighostvtd`: the same, ids from 193. Proxy
footprint afterwards 3.2 MB.

**64 tabs.** ⌘T up to the limit: 64 sessions held, the 65th tab shows the
"You already have 64 terminals open" card with Close Tab and Retry; the
strip scrolls with chips at their 200 pt floor; the ⋯ menu opens and works.
Idle round trips at 64 tabs: median 0.8 ms, max 10 ms. Footprint: app
**1.37 GB**, proxy 3.5 MB, io 3.3 MB. Closing 57 of them with ⌘W left 8
sessions and no zombie — but see "Known, not fixed" for the app's memory.

## Phase C — iPad

A virtual iPad on iPadOS 26, the roothide deb, installed over 1.0.8.

- **Move to New Window** from the context menu: the new window shows the
  tab's output and shell, and the tab leaves the source window.
- **Drag a tab out beside the window**: makes a new window holding the tab
  — but only after `uicache -p`. Installed over the same version, the
  bootstrap's uikittools trigger did not re-register the app, so
  LaunchServices still had the old `NSUserActivityTypes`. The postinst
  calls no `uicache` of its own; a version bump re-registers.
- **Title capsule** on the compact bar: fine.
- **Drag preview**: a dragged tab used to show an empty white card. On
  iPadOS 26 the SwiftUI `onDrag` `preview:` closure itself comes out empty,
  whatever it draws, so the preview is gone and the lift snapshot of the
  slot travels instead (`e189d98`); sidebar rows paint the theme's
  background under themselves so the card is solid. A row now shows its
  title; a strip chip still does not (below).
- Not run before the device was shut down: lock persistence across a
  relaunch, menus under a flood, the paste notice, and stress. Lock
  persistence and menus are covered on the Mac (phase B), the paste notice
  in phase A.

## Known, not fixed

- **About 16 MB per occluded surface** (phase A, above). On the Mac 64 tabs
  cost 1.37 GB.
- **The Mac app's memory does not come back after closing tabs.** From 64
  tabs down to 8, the footprint stayed at 1.35 GB 30 s later: 746 MB of
  owned, unmapped (GPU) memory and 275 MB of IOSurface. On the phone the
  same step returned it (1.06 GB → 166 MB). Either closed tabs' surfaces
  are kept alive on the Mac, or their renderer memory is released late;
  not investigated.
- **Main-thread stalls of 0.5–0.6 s** during window resizes and sidebar
  toggles on the Mac (above), with or without output. Not attributed.
- **The Mac strip can come to rest past its end after a drag-reorder.** In
  a scrolled strip, a chip dragged left left the row 33 pt past the
  capsule's end, the last chip's × clipped. Separately, a scroll to the
  first or last chip (`scrollTo(id)`, in `reveal` and the drag) stops with
  that chip against the capsule and the row's 4 pt end padding out of
  view. A fix that scrolls to the row's padded ends cured the second but
  not the first, and was taken out.
- **Tab order and window membership after a cold relaunch.** Tabs come
  back in session-id order, not the order they were in, and with several
  windows the first scene to connect claims every unattached session
  (`DaemonSessionDirectory.claimResumable`, then `TabManager.populate`)
  while the other windows open fresh shells. Pre-existing — the same at
  `67b85cb`; fixing it means persisting each window's order and membership.
- **Terminal modes are lost on reattach.** After a relaunch or reattach, a
  TUI that enabled DEC mode 2031 (colour-scheme reports, e.g. Claude Code)
  no longer hears dark/light changes. The daemon's replay keeps bytes, not
  terminal modes, and the `?2031h` has usually left the 256 KiB window, so
  the new surface never sends `CSI ?997;1/2n` and the program keeps its old
  theme and selection colour. The same loss applies to every mode a
  program sets once at startup: mouse reporting (1000/1002/1003/1006),
  focus events (1004), bracketed paste (2004), DECCKM. Diagnosed from code;
  not verified at runtime. The fix belongs in `ighostvtd-io`: `PTYSession`
  tracks these on/off modes from the output and sends them back ahead of
  the replay on attach (about 80 lines plus a harness test). An app-only
  fix is not safe — sending `?997` blind would type stray characters into a
  shell that never asked for it. Deferred past 1.0.9.

- **A strip chip's drag card is still blank on iPad.** The chip sits
  inside the bar's glass container, and the system's lift snapshot of
  glass content carries no text.
- **Replayed output wraps after a move to a narrower window.** The attach
  sends the new size and the shell redraws its prompt, but the replay
  bytes were written at the old width. Fixing it needs a library API to
  feed the replay at the old grid and reflow.

## Not run

- On the iPad: lock persistence, menus under a flood, the paste notice,
  stress. Move to New Window or multiple windows on a phone, which has
  neither.
- Out-of-range session attributes from an on-device client: it would have
  to stand in for `ighostvt-cli`, since the daemon admits a peer by its
  executable path. The harness covers them.
- On the Mac: the rapid New Tab/Close ×50 and New Window/Close ×20 churn
  (phase A ran the CLI and app churn on the phone), and a confirmed paste
  notice (above).
