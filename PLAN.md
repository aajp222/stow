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
| Remove after drag | Only when the drop succeeded; a cancelled or refused drag keeps the item. On by default, and becomes a setting in Phase 4. |
| Hiding a shelf with items | Use the hide button on the shelf, or the menu's Show/Hide Shelf toggle. The shelf comes back on the next file drag. |
| Hiding an empty shelf | When a drag ends, wait 0.3 s and for promised files to land (up to 10 s), then hide if the shelf is empty. |
| When it appears | Only when the drag pasteboard's `changeCount` moved since mouse-down *and* the drag carries files or file promises. Drags that start in Stow itself are ignored. |
| Where it docks | Left or right edge only, clear of the Dock and menu bar. It moves to the pointer's display on each new drag. It grows with its items up to 70% of the screen, then scrolls. |
| Promised files | `~/Library/Application Support/Stow/Promised/<one folder per drop>/`. Moved to the Trash when removed or cleared (10 minutes after a drag-out, so the receiving app can finish reading). Leftovers are trashed at launch. |
| Item model | `ShelfItem.Content` is an enum, so text, links and images slot in as new cases. |

## Phases

### Phase 1: Skeleton ✅ built
Menu bar icon (`tray`) with Show Shelf, Clear Shelf and Quit. No Dock icon, no window.

### Phase 2: The shelf ✅ built
- Non-activating floating `NSPanel` on every Space and over full-screen apps. It never takes focus.
- Translucent rounded background, 120 pt wide.
- `NSCollectionView` with a SwiftUI item view in each cell.
- Drop files and folders (stored as references) or file promises (screenshot thumbnails, Photos, Mail).
- Quick Look thumbnails and filenames.
- Drag one or several items out.
- Right-click menu: Reveal in Finder, Remove.

### Phase 3: Auto-appear on drag ✅ built
Global and local mouse monitors plus the drag pasteboard check above. The shelf slides in at the nearer edge of the pointer's display.

### Phase 4: Polish (after Phases 1–3 are approved)
- Persist items across relaunches with bookmark data; drop items whose files are gone. Promised files still on the shelf survive the launch cleanup.
- Spacebar opens Quick Look on the selected item. The panel has to become key for this, without activating Stow.
- Global hotkey ⌃⌥S toggles the shelf, via Carbon `RegisterEventHotKey`. Don't switch to an Option-only shortcut, because macOS 15+ rejects those.
- Accept text, URLs and images as items. The drag monitor then shows the shelf for those drags too.
- Settings window: an AppKit window with SwiftUI inside. Options:
  - Remove after drag.
  - Launch at login via `SMAppService`. Test it from /Applications.
  - Preferred edge: Left / Right / Nearest to pointer.
  - Only appear when the pointer nears a screen edge.

### Phase 5: Liquid Glass look
Replace the `NSVisualEffectView` background with `NSGlassEffectView`, in one place: `ShelfViewController.makeBackground()`. Then restyle the header and cells to match.

## Code map

| File | Role |
|---|---|
| `AppDelegate.swift` | Entry point, menu bar item, wires everything together |
| `ShelfPanel.swift` | The `NSPanel` subclass and its window configuration |
| `ShelfPanelController.swift` | Show/hide, slide animation, docking, reacting to drags |
| `ShelfViewController.swift` | Shelf contents: header, list, empty state, drag-out handling |
| `ShelfCollectionView.swift` | Collection view (copy vs ⌘-move, context menu) and the cell hosting SwiftUI |
| `ShelfItemView.swift` | SwiftUI thumbnail + filename |
| `ShelfDropView.swift` | Drop target: file URLs and file promises |
| `ShelfViewModel.swift` | The items; adding, removing, receiving promises |
| `ShelfItem.swift` | The item model |
| `PromisedFileStore.swift` | The Promised folder: create, trash, clean up |
| `DragMonitor.swift` | Notices file drags anywhere on the Mac |
| `ThumbnailProvider.swift` | Finder icons and QuickLookThumbnailing previews |
