# Stow on App Store Connect and TestFlight

The project is already set up for the App Store: App Sandbox, app icon, category, the encryption answer and a privacy manifest. What's left are the steps only you can do in App Store Connect and Xcode. The texts to paste are further down.

## 1. Create the app in App Store Connect (once)

1. Go to https://appstoreconnect.apple.com → **Apps** → **+** → **New App**.
2. Fill in:
   - **Platform:** macOS
   - **Name:** Stow. Names are unique across the App Store; if it's taken, try "Stow Shelf" or "Stow – Drag Shelf". Only the store name changes; the app itself stays "Stow".
   - **Primary language:** English (U.S.)
   - **Bundle ID:** `com.aaryanjigarpanchal.Stow`. If it isn't in the list yet, do step 2 below once first; Xcode registers it for you.
   - **SKU:** `stow-mac` (for your records only)
   - **User access:** Full access

## 2. Upload a build from Xcode (each time)

1. Pull the latest `main` and open `Stow.xcodeproj`.
2. Select the **Stow** target, then **Signing & Capabilities**. Check **Automatically manage signing** and choose your paid team.
3. In the toolbar's destination menu, choose **Any Mac (Apple Silicon, Intel)**.
4. Choose **Product → Archive**. When it's done, the Organizer window opens.
5. Click **Distribute App** → **App Store Connect** (or "TestFlight & App Store") → **Distribute**.
   Xcode makes the App Store certificate and profile and uploads the build. Leave "Manage Version and Build Number" on, so every upload gets a new build number automatically.
6. App Store Connect emails you when the build has finished processing, usually within 10–30 minutes.

## 3. Send it to testers with TestFlight

1. In App Store Connect → **Stow** → **TestFlight**.
2. Under **Test Information**, paste the "Beta App Description", "What to Test", feedback email and privacy policy URL from below.
3. **Friends (external testers):** click **+** next to External Testing and create a group, say "Friends". Add their emails, or turn on a **public link** you can text them. Add the build and click **Submit for Review**. The first build of a new app needs a quick Beta App Review, usually about a day; later builds are often approved straight away.
4. **Internal testers:** people you've added to your App Store Connect team can test right away, with no review.
5. Testers install **TestFlight** from the Mac App Store, open your invite, and click **Install**. They need **macOS 26 (Tahoe) or later**.

## Texts to paste

**Beta App Description**

> Stow is a menu bar shelf for drag and drop. Park files, photos, text and links while you move between apps, then drag them wherever they need to go.

**What to Test**

> Thanks for testing Stow! It lives in the menu bar (the tray icon); there's no Dock icon.
> 1. Pick up a file in Finder. Does the shelf slide in? Drop the file on it, then drag it out into another folder or an email.
> 2. Drop in a screenshot thumbnail (⌘⇧4), a photo from Photos, some selected text, and a link from a browser.
> 3. Right-click items and try Open With, Share, Rename, Move, Copy, Show in Finder, Remove and Restore Last Removed Files.
> 4. Click an item and press Space for Quick Look.
> 5. Press ⌃⌥S to show or hide the shelf. Drag the shelf by its header to move it.
> 6. Quit and reopen Stow; your items should still be there.
> 7. Tray icon → Settings…: try the options.
>
> Tell me about anything that doesn't show up when it should, looks wrong, or is confusing.

**Feedback email:** your email address.

**Privacy Policy URL:** https://github.com/aajp222/stow/blob/main/PRIVACY.md

## For a public App Store release later

| Field | Suggested value |
|---|---|
| Subtitle (30 max) | A shelf for your drags |
| Category | Productivity (secondary: Utilities) |
| Keywords (100 max) | drag,drop,shelf,files,clipboard,screenshots,stash,menu bar,organizer,productivity |
| Promotional text | Drag anything, drop it on the shelf, and pick it up again whenever you're ready. |
| Support URL | https://github.com/aajp222/stow/issues |
| Privacy Policy URL | https://github.com/aajp222/stow/blob/main/PRIVACY.md |
| App Privacy | Data Not Collected |
| Age rating | Answer "None" to everything (rated 4+) |
| Screenshots | At least one, 2880 × 1800 (or 1440 × 900). Show the shelf with a few items next to a Finder window. |

**Description**

> Stow is a little shelf for everything you're dragging around your Mac.
>
> Pick up files, photos, text or links in any app and Stow slides in at the side of your screen. Drop them on the shelf, go find where they belong, whether that's another folder, another Space, an email or a browser upload, and drag them back out one at a time or all together.
>
> • Appears automatically when you start dragging, on whichever display you're using
> • Holds files and folders without copying them, plus screenshots, photos, text and web links
> • Quick Look thumbnails; press Space to preview
> • Drag several items out at once, and have them leave the shelf once dropped (optional)
> • Put the shelf anywhere, or let it dock to the nearest side
> • Right-click for Open With, Share, Rename, Move, Copy and Show in Finder
> • ⌃⌥S shows or hides the shelf from anywhere
> • Liquid Glass design, made for macOS Tahoe
> • No accounts and no tracking; everything stays on your Mac
