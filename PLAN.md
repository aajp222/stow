# Stow: plan

Stow is a personal macOS drag-and-drop shelf that lives in the menu bar. It's an original app and doesn't use Yoink's name, icon or assets.

## Tech decisions

- Swift. AppKit handles windows and drag-and-drop; SwiftUI draws each shelf item.
- macOS 26+ (changed from 14+ so the shelf can use Liquid Glass).
- App Sandbox off. Menu bar only: `LSUIElement = YES`, so there's no Dock icon.
- No third-party dependencies unless approved.
- `ShelfViewModel` is the single source of truth for the shelf's items.
- No permissions. Global *mouse* monitors don't need Accessibility access, and the hotkey uses Carbon `RegisterEventHotKey`, which doesn't need it either.
- Commit after each phase. CI (`.github/workflows/build.yml`) runs `xcodebuild` on every push.

## Behaviour decisions

| Topic | Decision |
|---|---|
| Dragging out | The shelf holds the *original* files, so a plain drag copies. Hold ⌘ during the drag to move. After a move the item is always removed. |
| Remove after drag | Only when the drop succeeded; a cancelled or refused drag keeps the item. On by default; a setting. |
| Hiding a shelf with items | Use the hide button on the shelf, or the menu's Show/Hide Shelf toggle. The shelf comes back on the next file drag. |
| Hiding an empty shelf | When a drag ends, wait 0.3 s and for promised files to land (up to 10 s), then hide if the shelf is empty. |
| When it appears | Whenever something the shelf can take (a file, folder, file promise, link, text or image) is picked up in any app: the drag pasteboard's `changeCount` moved since the last mouse-up *and* the shelf can accept what's on it. Detection polls while the button is held and re-checks if the drag data changes mid-drag. The legacy `NSFilenamesPboardType` counts too. The monitor looks only at the drag's *types*, never its data: since macOS 26, reading another app's pasteboard data without the user pasting or dropping is blocked. Drags that start in Stow itself are ignored. |
| Where it sits | Drag the shelf by any empty part (header, labels, blank area) to put it anywhere. The spot is saved relative to the display, so it shows up in the same place on whichever display the pointer is on, and it survives relaunches. It grows downward, pushed up if it would run off the bottom. The menu's Reset Shelf Position goes back to automatic: the left or right edge nearest the pointer, vertically centred, clear of the Dock and menu bar. It grows with its items up to the "Items shown before scrolling" setting (default 4, never more than 70% of the screen), then scrolls; new items scroll into view. Settings can pin automatic docking to the left or right side. Optionally it waits until a drag reaches the side of the screen. |
| Promised files | `~/Library/Application Support/Stow/Promised/<one folder per drop>/`. Moved to the Trash when removed or cleared (10 minutes after a drag-out, so the receiving app can finish reading). Leftovers are trashed at launch. |
| Right-click menu | On items: Open With ▸ (the default app, the others, and Other…), Share…, Rename… (renames the real file), Move…, Copy (to paste in Finder or Mail), Show in Finder, Remove, Restore Last Removed Files, Add Clipboard Contents to Stow. On empty space: just the last two. macOS adds Ask Siri (macOS 27) and Services ▸ itself; Services works because the list offers its selected files to services. Restore brings back the latest Remove, Clear or drag-out batch, pulling Stow copies back out of the Trash. Add Clipboard Contents works like a drop. Text items get Copy, Share and Remove; links also get Open Link. |
| Item model | `ShelfItem.Content` is `.file`, `.text` or `.link`. Images that aren't files yet (image data from a drag or the clipboard) are saved as PNGs in Stow's folder and become file items, so they drag out anywhere a file can. One reader (`PasteboardContents`) handles drops and the clipboard, preferring files/promises, then links, then an image, then text. |
| Keyboard | Clicking an item makes the shelf the key window (it's non-activating, so your app stays active). Space toggles Quick Look on the selected files (Stow activates while it's open, then hands back). Delete removes the selection. ⌃⌥S shows/hides the shelf from anywhere. |
| Saving | `~/Library/Application Support/Stow/Shelf.plist`, rewritten on every change. Files are stored as bookmarks, so renamed or moved files are still found; missing or trashed files are dropped at launch. Stow copies still on the shelf survive the launch cleanup. A shelf that had items reappears at launch. |

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
The shelf's background is an `NSGlassEffectView` (`ShelfViewController.makeGlassBackground()`), with 20 pt corners. Everything visible sits inside the glass view's `contentView`. While files hover over the shelf, the glass takes an accent tint.

## Releases

`.github/workflows/release.yml` builds a Release version of Stow for Apple Silicon and Intel, zips it, and publishes it as a GitHub Release with install steps. To publish, go to Actions → Release → Run workflow and enter a version such as `1.1`; pushing a `v1.1` tag also works. Friends download from https://github.com/aajp222/stow/releases/latest.

The app is signed ad hoc, not with a paid Developer ID, so on another Mac the first launch must be allowed once in System Settings → Privacy & Security → Open Anyway. Removing that step would take the Apple Developer Program: a Developer ID signature plus notarization.

## Code map

| File | Role |
|---|---|
| `AppDelegate.swift` | Entry point, menu bar item, wires everything together |
| `ShelfPanel.swift` | The `NSPanel` subclass and its window configuration |
| `ShelfPanelController.swift` | Show/hide, slide animation, docking, reacting to drags |
| `ShelfViewController.swift` | Shelf contents: header, list, empty state, drag-out handling |
| `ShelfCollectionView.swift` | Collection view (copy vs ⌘-move, context menu) and the cell hosting SwiftUI |
| `ShelfItemView.swift` | SwiftUI preview (thumbnail, text card or link badge) + name |
| `ShelfDropView.swift` | Drop target |
| `PasteboardContents.swift` | Reads files, promises, links, text and images from a drop or the clipboard |
| `ShelfContextMenu.swift` | The right-click menus and their commands |
| `ShelfArchive.swift` | Saves and loads the shelf (bookmarks), autosave |
| `AppSettings.swift` | Settings, stored in UserDefaults; open at login |
| `SettingsWindow.swift` | The Settings window and its SwiftUI form |
| `HotKey.swift` | The ⌃⌥S global shortcut |
| `ShelfViewModel.swift` | The items; adding, removing, receiving promises |
| `ShelfItem.swift` | The item model |
| `PromisedFileStore.swift` | The Promised folder: create, trash, clean up |
| `DragMonitor.swift` | Notices drags anywhere on the Mac |
| `ThumbnailProvider.swift` | Finder icons and QuickLookThumbnailing previews |
