# Stow: plan

Stow is a personal macOS drag-and-drop shelf that lives in the menu bar. It's an original app and doesn't use Yoink's name, icon or assets.

## Tech decisions

- Swift. AppKit handles windows and drag-and-drop; SwiftUI draws each shelf item.
- macOS 26+ (changed from 14+ so the shelf can use Liquid Glass).
- App Sandbox **on** (changed from off, because the App Store requires it). Access to dropped and chosen files is `ENABLE_USER_SELECTED_FILES = readwrite`; security-scoped bookmarks come from `Stow.entitlements`. Menu bar only: `LSUIElement = YES`, so there's no Dock icon.
- No third-party dependencies unless approved.
- `ShelfViewModel` is the single source of truth for the shelf's items.
- No permissions. Global *mouse* monitors don't need Accessibility access, and the hotkey uses Carbon `RegisterEventHotKey`, which doesn't need it either.
- Commit after each phase. CI (`.github/workflows/build.yml`) runs `xcodebuild` on every push.

## Behaviour decisions

| Topic | Decision |
|---|---|
| Dragging out | The shelf holds the *original* files, so a plain drag copies. Hold ⌘ during the drag to move. After a move the item is always removed. |
| Remove after drag | Only when the drop succeeded; a cancelled or refused drag keeps the item. On by default; a setting. |
| Removing by hand | A ✕ appears in an item's top-left corner while the pointer is over it. Or "flick" items off: drag them more than 60 pt away from the shelf and let go where nothing takes them, and they vanish in a puff of smoke. Esc (button still down) cancels without removing, and items let go near the shelf slide back. Either way, Restore Last Removed Files brings them back. |
| Stacks | Two or more files dropped at once (file promises included) become one stack: a row showing up to three of them fanned out, with a count. Dragging the stack drags all its files (one dragging item per file). Clicking it fans it open: its items follow as tinted rows you can drag, open or remove one by one; an item dragged out of an open stack and dropped back on the shelf leaves the stack. Stack Items / Unstack in the right-click menu; a setting turns stacking off. A stack's members always sit together in `items`; `ShelfRow` turns the items into rows. |
| Reordering | Drag items within the shelf; an accent line shows where they'll land, and the list scrolls near its top and bottom. Items never land between an open stack's rows. The shelf starts its own drag session (`ShelfDragSource`) rather than NSCollectionView's, so stacks can carry several files. |
| Hiding a shelf with items | Use the hide button on the shelf, or the menu's Show/Hide Shelf toggle. The shelf comes back on the next file drag. |
| Hiding an empty shelf | When a drag ends, wait 0.3 s and for promised files to land (up to 10 s), then hide if the shelf is empty. |
| When it appears | Whenever something the shelf can take (a file, folder, file promise, link, text or image) is picked up in any app: the drag pasteboard's `changeCount` moved since the last mouse-up *and* the shelf can accept what's on it. Detection polls while the button is held and re-checks if the drag data changes mid-drag. The legacy `NSFilenamesPboardType` counts too. The monitor looks only at the drag's *types*, never its data: since macOS 26, reading another app's pasteboard data without the user pasting or dropping is blocked. Drags that start in Stow itself are ignored. |
| Where it sits | Drag the shelf by any empty part (header, labels, blank area) to put it anywhere. The spot is saved relative to the display, so it shows up in the same place on whichever display the pointer is on, and it survives relaunches. It grows downward, pushed up if it would run off the bottom. The menu's Reset Shelf Position goes back to automatic: the left or right edge nearest the pointer, vertically centred, clear of the Dock and menu bar. It grows with its items up to the "Items shown before scrolling" setting (default 4, never more than 70% of the screen), then scrolls; new items scroll into view. Settings can pin automatic docking to the left or right side. Optionally it waits until a drag reaches the side of the screen. |
| Promised files | `~/Library/Application Support/Stow/Promised/<one folder per drop>/`. Moved to the Trash when removed or cleared (10 minutes after a drag-out, so the receiving app can finish reading). Leftovers are trashed at launch. |
| Right-click menu | On items: Open, Open With ▸ (the default app, the others, and Other…), Share…, Rename… (renames the real file), Move…, Copy (to paste in Finder or Mail), Show in Finder, Stack Items / Unstack, Remove, Restore Last Removed Files, Add Clipboard Contents to Stow. On empty space: just the last two. macOS adds Ask Siri (macOS 27) and Services ▸ itself; Services works because the list offers its selected files to services. Restore brings back the latest Remove, Clear or drag-out batch, pulling Stow copies back out of the Trash. Add Clipboard Contents works like a drop. Text items get Copy, Share and Remove; links get Open Link instead of Open. |
| Item model | `ShelfItem.Content` is `.file`, `.text` or `.link`. Images that aren't files yet (image data from a drag or the clipboard) are saved as PNGs in Stow's folder and become file items, so they drag out anywhere a file can. One reader (`PasteboardContents`) handles drops and the clipboard, preferring files/promises, then links, then an image, then text. |
| Keyboard | Clicking an item, or showing the shelf with the shortcut, makes the shelf the key window (it's non-activating, so your app stays active). Then: ↑/↓ move the selection (⇧ extends), → / ← open and close stacks, Return opens (or opens/closes a selected stack), Space toggles Quick Look (Stow activates while it's open, then hands back), ⌘C copies, ⌘A selects all, Delete removes. Typing letters filters by name (the header shows the filter; Delete takes a letter back, Esc clears it, hiding the shelf resets it). Clicks work like Finder: ⌘-click toggles, ⇧-click selects a range, double-click opens. The show/hide shortcut is ⌃⌥S by default; Settings can record another (at least one of ⌘⌃⌥, or an F-key) or turn it off. |
| Menu bar | The icon is `tray` when the shelf is empty and `tray.full` with the item count next to it when it isn't. The count is a setting. |
| Accessibility | VoiceOver reads each row as one button: "name, kind" (Finder's kind, such as "PDF document"), "Stack of 3 items, closed", or "…, in a stack". Press opens (or opens/closes a stack); a Remove action removes. Reduce Motion turns off the shelf's slide (it only fades), the puff of smoke, and slide-back after a flick. |
| Saving | `Shelf.plist` in Stow's sandbox container (`~/Library/Containers/com.aaryanjigarpanchal.Stow/…/Application Support/Stow/`), rewritten on every change. Files are stored as security-scoped bookmarks, so renamed or moved files are still found and the sandbox lets Stow reopen them; missing or trashed files are dropped at launch. Stow copies still on the shelf survive the launch cleanup. A shelf that had items reappears at launch. |
| Sandbox and files | Dropping a file gives Stow access to that file only. Rename… and Move… also change the folder the file is in, so the first time the sandbox refuses, Stow shows an Open panel asking you to allow that folder. It keeps the access for the session. Removed Stow copies stay put while they can still be restored (the sandbox can't take files back out of the Trash) and go to the Trash when a newer removal replaces them, at least 10 minutes after removal. |

## Phases

### Phase 1: Skeleton ✅ working
Menu bar icon (`tray`) with Show Shelf, Clear Shelf and Quit. No Dock icon, no window.

### Phase 2: The shelf ✅ working
- Non-activating floating `NSPanel` on every Space and over full-screen apps. It never takes focus.
- Rounded background, 120 pt wide (Liquid Glass since Phase 5).
- `NSCollectionView` with a SwiftUI item view in each cell.
- Drop files and folders (stored as references) or file promises (screenshot thumbnails, Photos, Mail).
- Quick Look thumbnails and filenames.
- Drag one or several items out.
- Right-click menu (now the full menu in the table above).

### Phase 3: Auto-appear on drag ✅ working
Global and local mouse monitors plus the drag pasteboard check above. The shelf slides in on the pointer's display.

### Phase 3.5: Free placement, more reliable pop-up ✅ working
Drag the shelf anywhere, with the spot remembered and a Reset Shelf Position menu item. Detection hardening for "every file pick-up in any app" (see When it appears).

### Phase 4: Polish ✅ built
- Persist items across relaunches with bookmark data; drop items whose files are gone. Promised files still on the shelf survive the launch cleanup.
- Spacebar opens Quick Look on the selected item. The panel becomes key for this, without activating Stow.
- Global hotkey ⌃⌥S toggles the shelf, via Carbon `RegisterEventHotKey`. Don't switch to an Option-only shortcut, because macOS 15+ rejects those.
- Accept text, URLs and images as items. The drag monitor shows the shelf for those drags too.
- Settings window (menu bar → Settings…, ⌘,): an AppKit window with SwiftUI inside. Options:
  - Open Stow when you log in (`SMAppService`). Test it from /Applications.
  - Remove items after dragging them out.
  - Items shown before scrolling (1–12, default 4).
  - Dock to: side nearest the pointer, left side or right side. Dragging the shelf anywhere still works.
  - Only show when a drag reaches the side of the screen.

### Phase 5: Liquid Glass look ✅ built (done ahead of Phase 4)
The shelf's background is an `NSGlassEffectView` (`ShelfViewController.configureGlassBackground()`), with 20 pt corners. Everything visible sits inside the glass view's `contentView`. While files hover over the shelf, the glass takes an accent tint.

### Phase 6: Stacks, reordering, keyboard ✅ built
Stacks, reordering, the hover ✕ and flicking off, the menu bar count, full keyboard control with type-to-filter, a custom shortcut, and VoiceOver/Reduce Motion support (see the table above). New settings: Stack files dropped together, Show the number of items in the menu bar, and the shortcut recorder.

## App Store and TestFlight

Everything the App Store checks is in the project: sandbox, app icon (`Stow/Assets.xcassets/AppIcon.appiconset`, original artwork), `LSApplicationCategoryType` (Productivity), `ITSAppUsesNonExemptEncryption = NO` (`Stow-Info.plist`), a privacy manifest (`Stow/PrivacyInfo.xcprivacy`) and a privacy policy (`PRIVACY.md`). `APPSTORE.md` has the steps (create the app in App Store Connect, Archive → Distribute in Xcode, TestFlight groups) and the texts to paste.

## Releases

`.github/workflows/release.yml` builds a Release version of Stow for Apple Silicon and Intel, zips it, and publishes it as a GitHub Release with install steps. To publish, go to Actions → Release → Run workflow and enter a version such as `1.1`; pushing a `v1.1` tag also works. Friends download from https://github.com/aajp222/stow/releases/latest.

- **With the five Developer ID secrets set** (repo Settings → Secrets and variables → Actions; the names are listed at the top of `release.yml`), the app is signed with the Developer ID certificate. It uses the hardened runtime and a secure timestamp, is notarized with `notarytool`, and has the approval stapled to it. It then opens on any Mac with just macOS's normal "downloaded from the internet" prompt.
- **Without them**, it's signed ad hoc and macOS warns that it can't check it for malware. The release notes then tell people to run `xattr -dr com.apple.quarantine /Applications/Stow.app` once, or to use Privacy & Security → Open Anyway.

Bundle ID: `com.aaryanjigarpanchal.Stow`.

## Code map

| File | Role |
|---|---|
| `AppDelegate.swift` | Entry point, menu bar item, wires everything together |
| `ShelfPanel.swift` | The `NSPanel` subclass and its window configuration |
| `ShelfPanelController.swift` | Show/hide, slide animation, docking, reacting to drags |
| `ShelfViewController.swift` | Shelf contents: header, list, empty state, filter, stacks opening and closing, drags out, reordering, flicking off |
| `ShelfCollectionView.swift` | The list: Finder-style clicks and selection, the ✕, keyboard, Quick Look, Services, and the cell hosting SwiftUI (hover, VoiceOver) |
| `ShelfItemView.swift` | SwiftUI row: preview (thumbnail, text card, link badge or fanned stack) + name, and the ✕ |
| `ShelfRow.swift` | Turns items into rows: items, stacks, and the members of open stacks; filtering |
| `ShelfDragSource.swift` | The drag source for items dragged off the shelf (copy vs ⌘-move) |
| `ShelfDropView.swift` | Drop target, for new items and for reordering |
| `PasteboardContents.swift` | Reads files, promises, links, text and images from a drop or the clipboard |
| `ShelfContextMenu.swift` | The right-click menus and their commands |
| `ShelfArchive.swift` | Saves and loads the shelf (bookmarks), autosave |
| `AppSettings.swift` | Settings, stored in UserDefaults; open at login |
| `SettingsWindow.swift` | The Settings window and its SwiftUI form |
| `HotKey.swift` | The global show/hide shortcut |
| `ShortcutRecorder.swift` | The Settings control that records a new shortcut |
| `Stow.entitlements`, `Stow-Info.plist`, `Stow/PrivacyInfo.xcprivacy` | Sandbox bookmarks entitlement, extra Info.plist keys, privacy manifest |
| `ShelfViewModel.swift` | The items; adding, removing, receiving promises, reordering, stacking |
| `ShelfItem.swift` | The item model |
| `PromisedFileStore.swift` | The Promised folder: create, trash, clean up |
| `DragMonitor.swift` | Notices drags anywhere on the Mac |
| `ThumbnailProvider.swift` | Finder icons and QuickLookThumbnailing previews |
