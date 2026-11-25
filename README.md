<h1 align="center">
  <br>
  <a href="https://getchora.vercel.app/"><img src="https://getchora.vercel.app/logo.png" alt="Chora" width="120"></a>
  <br>
  Chora
  <br>
</h1>

<p align="center">
  Sound, time and space, right in your MacBook's notch.<br>
  A per-app volume mixer, a calendar you can edit, a timer and a music player that live at the top of your Mac.
</p>

<p align="center">
  <a href="https://github.com/ronaldw07/boring.notch/releases/latest/download/Chora.dmg"><b>Download</b></a> ·
  <a href="https://getchora.vercel.app/">Website</a> ·
  <a href="https://getchora.vercel.app/changelog.html">What's new</a> ·
  <a href="https://discord.gg/8GVjCq4fE5">Discord</a>
</p>

<p align="center">
  <img src="https://getchora.vercel.app/shots/volume.png" width="49%" alt="A master volume slider and one for each app" />
  <img src="https://getchora.vercel.app/shots/calendar.png" width="49%" alt="The day as a timeline you can drag" />
</p>

---

## Why Chora

The notch is the most visible space on a MacBook, and most apps leave it
empty. Meanwhile the small things I reach for all day are scattered: turning
one app down means turning everything down, checking the next meeting means
opening a calendar, and a timer is yet another app. Each interruption is
small; together they break focus dozens of times a day.

Chora turns the notch into a place to do those things in one glance and one
action, without opening anything.

## What it does

- **Volume, per app.** A master slider plus one for each app. Turn a call
  down without touching your music.
- **A calendar you can edit.** See one day, 4 days, a week or a month,
  with the weather for each. Drag events to move them, pull the bottom edge
  to change the time, drag the notch taller to see more, and undo any
  change, including ones sent to Google (⌘Z works too). Drag on an empty spot to create an event, or type
  one ("Lunch with Sam 1pm"), make it repeat on any schedule or remind you,
  copy and paste it, duplicate it, move it to another calendar or give it
  a color, or join its call from its details. A
  heads-up beside the notch says when the next event starts in 5 minutes.
  Search a year of events, answer Google invites and add a Meet link.
  Google Tasks show on every day, and you can edit them and give them a
  time. Events come from the Mac's
  own accounts (Google, iCloud, Outlook), so nobody signs in to see them,
  and the Google extras are one Sign in with Google click.
- **A timer that forgives mistakes.** Lengths down to the second, recent
  lengths one tap away, and undo after an accidental reset.
- **Music that shares the space.** Album art, a live visualizer and synced
  lyrics, and it follows Spotify even when a paused browser tab is holding
  macOS's Now Playing. A running timer sits beside the music instead of
  replacing it.
- **Quick to move around.** Hover the notch and press 1 to 5 to switch tabs
  (or ⌥1 to ⌥5 from anywhere while it's open), the calendar has its own
  keyboard shortcuts, a shelf holds files you drop on the notch, and
  clipboard history brings back anything you copied.

## How it's built and shipped

- **Small releases, often.** 27 versions since September 2026, each with a
  plain-language entry in the [changelog](./CHANGELOG.md) that doubles as the
  in-app update note and the website's "What's new".
- **Updates install themselves.** Signed releases go out through an in-app
  updater that checks hourly and installs as soon as a new version
  downloads, so a fix reaches everyone within the hour, no reinstall.
- **A public roadmap shaped by users.** The website's "Coming soon" list and
  a feedback form feed what gets built next, and the Discord is where early
  versions get tried first.
- **Design rules over feature count.** Every tab has to fit a short, wide
  space and do one thing fast; anything that needs a full window doesn't
  belong in the notch.

## Install

Requires an Apple silicon Mac on macOS 14 Sonoma or later.

1. [Download Chora.dmg](https://github.com/ronaldw07/boring.notch/releases/latest/download/Chora.dmg),
   open it and drag **Chora** to Applications.
2. Open Chora. Chora isn't notarized by Apple yet, so macOS stops it the
   first time: click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down and click
   **Open Anyway**. Then hover over the notch. Later updates install on
   their own.

## Build from source

Needs macOS 15.6 or later and Xcode 26 or later.

```bash
git clone https://github.com/ronaldw07/boring.notch.git
cd boring.notch
open boringNotch.xcodeproj
```

Then press **Cmd + R**.

## Feedback

Found a bug or want something? Use the
[feedback form](https://docs.google.com/forms/d/e/1FAIpQLSfXjYQT4DGm7UDg0RwTEFJR07rIt27WWSCMr_0hVcjNfF8teA/viewform)
or say hi in the [Discord](https://discord.gg/8GVjCq4fE5).

## Credits

Chora is built on [boring.notch](https://github.com/TheBoredTeam/boring.notch)
by TheBoredTeam, released under GPL-3.0, and is released under the same
license. Thanks to them and to the open-source projects it relies on,
including [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)
for Now Playing on macOS 15.4+ and
[NotchDrop](https://github.com/Lakr233/NotchDrop), which shaped the first
version of the shelf. Full attributions are in
[Third-Party Licenses](./THIRD_PARTY_LICENSES).
