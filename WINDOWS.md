# Stow for Windows: plan

A native Windows version of Stow. The Mac app stays as it is; `PLAN.md`'s behaviour table is the spec this version is built against, and where Windows needs something different, this file says so.

## Tech decisions

- C# on .NET 10 (the current long-term release) with WPF. Drag-and-drop between apps, window styles, the mouse hook and the tray icon go straight to Win32 through P/Invoke and COM interop, because WPF's own drag-and-drop hides the parts Stow needs.
- Windows 11 only. Windows 10 support ended in October 2025.
- Builds for x64 (most PCs) and ARM64 (the Windows VM on an Apple Silicon Mac, and Snapdragon PCs).
- No third-party dependencies unless approved. Combine into PDF will need one later (PdfSharp, MIT); everything else is built into .NET or Windows.
- The code lives in `windows/` in this repo. `windows/Directory.Build.props` sets `EnableWindowsTargeting`, so it compiles on a Mac too (for checking); it only runs on Windows.
- Testing happens by hand in a Windows 11 VM on the Mac and on a real PC.
- CI: `.github/workflows/windows.yml` builds on a GitHub-hosted Windows machine whenever something in `windows/` changes, and keeps the `.exe` files as downloadable artifacts. The Mac workflow (`build.yml`) skips pushes that only touch the Windows side.
- Commit after each approved phase.

## Building

The .NET 10 SDK is installed in `~/.dotnet` on the Mac (Microsoft's install script; no admin rights needed). From the repo root:

```bash
~/.dotnet/dotnet publish windows/Lab/StowLab.csproj -c Release -r win-arm64 -o windows/out/win-arm64
~/.dotnet/dotnet publish windows/Lab/StowLab.csproj -c Release -r win-x64 -o windows/out/win-x64
```

Each produces one self-contained `StowLab.exe` that runs without installing anything. Use the ARM64 one in the VM (copy it through the VM's shared folder) and the x64 one on an Intel or AMD PC. It isn't signed yet, so Windows SmartScreen says "Windows protected your PC" the first time: click **More info → Run anyway**.

## How Mac features map to Windows

| Stow on Mac | Stow on Windows |
|---|---|
| Menu bar icon with the item count | Notification-area (tray) icon with the count drawn on it. Windows 11 puts new tray icons in the overflow, so you pin it once. |
| Non-activating `NSPanel` on every Space, Liquid Glass | Always-on-top window with `WS_EX_NOACTIVATE` (never takes focus) and `WS_EX_TOOLWINDOW` (no taskbar button). Acrylic or Mica background and rounded corners from DWM. |
| Drag pasteboard `changeCount` | No equivalent: Windows passes drag data straight from the source app to the target. See "Noticing drags" below. |
| File promises | "Virtual files" (`FileGroupDescriptorW` + `FileContents`): Outlook attachments, browser images, files inside zips. Saved to `%LOCALAPPDATA%\Stow\Promised\<one folder per drop>\`. |
| Drag out copies, ⌘ moves | Copies by default; **Shift** moves (Windows' own move key). |
| QuickLookThumbnailing | The shell's own thumbnails (`IShellItemImageFactory`), the same ones File Explorer shows |
| Quick Look (Space) | Stow's own preview window, hosting the same preview handlers as File Explorer's preview pane |
| Security-scoped bookmarks | Path plus NTFS file ID; `OpenFileById` finds a file that was renamed or moved on the same drive. Saved as JSON in `%APPDATA%\Stow`. |
| Carbon `RegisterEventHotKey` | `RegisterHotKey`, which needs no permission. Default Ctrl+Alt+S. |
| Open at login (`SMAppService`) | The `Run` key under `HKEY_CURRENT_USER` |
| Share menu extension | **Send to ▸ Stow** in File Explorer's right-click menu first; Windows' Share sheet later (it needs an MSIX package). |
| Screenshot watcher | Watch `Pictures\Screenshots`, where Snipping Tool saves screenshots |
| Open With, Share…, Show in Finder | Windows' Open With dialog, the Windows share sheet, Show in File Explorer |
| Quick actions | Zip, image conversion and resizing are built in (HEIC needs Microsoft's HEIF extension). Combine into PDF needs a library. |
| VoiceOver | Narrator, through UI Automation |
| Haptics, Services, Ask Siri | Dropped; no Windows equivalent |
| Developer ID and notarization | Code signing, or the Microsoft Store (decided in Phase 6) |

## The hard parts

1. **Noticing drags.** A low-level mouse hook (`WH_MOUSE_LL`, which Windows doesn't ask permission for) sees the button go down and the pointer move. That switches on invisible 2 px strips along each display's left and right edges, which take part in drag-and-drop. When a drag touches one, Stow checks what's being dragged, and if the shelf can take it, the shelf slides in. The strips let clicks through (`WS_EX_TRANSPARENT`) whenever no drag is under way, so they never block a maximised window's scroll bar. "As soon as you drag" (the Mac default) needs a way to tell a file drag from moving a window or selecting text; Phase 0 tries one (see the Lab) and decides whether it's reliable.
2. **Keyboard focus.** A `WS_EX_NOACTIVATE` window can't receive typing. Arrow keys, type-to-filter and Space-to-preview need the shelf to take focus when clicked or summoned, then hand it back to the app you were in.
3. **Knowing a drag out worked.** When File Explorer moves a file on the same drive, it reports "nothing happened" and writes what it really did ("Performed DropEffect") back into the drag's data. Remove-after-drag has to read that.
4. **Displays with different scaling.** The app is per-monitor DPI aware (`app.manifest`), and anything placed in physical pixels has to be placed again after Windows rescales it.
5. **Apps running as administrator.** Windows blocks drags from them into normal apps. That can't be fixed; it gets documented.

## Phases

Each phase ends with a build, a list of things to test by hand, and a stop until they work.

### Phase 0: setup and the Lab ⏳ ready to test
- .NET SDK on the Mac, the `windows/` folder, the Windows CI workflow.
- **Stow Lab** (`windows/Lab/`): a throwaway test app that tries the risky parts before the real app is built:
  - noticing drags: the mouse hook, the edge strips, shake to summon, and the "as soon as you drag" guess, logging what it sees;
  - a shelf window that never takes focus, with an Acrylic/Mica/solid background, taking drops (files, virtual files, links, text) and dragging items back out;
  - two ways of making a drag out copy by default and move with Shift, reporting what the target actually did;
  - taking keyboard focus and handing it back;
  - whether the shelf shows on every virtual desktop and over full-screen apps.
- The Lab logs everything to its window and to `%LOCALAPPDATA%\StowLab\lab.log`. Copy Log puts the whole log on the clipboard.

#### Phase 0 tests

Use throwaway files. Some of these tests move files, and finding out whether they do is the point.

Do these in the VM, and again on the PC (it matters most for the two-display and scaling tests). Leave the Lab window open; the shelf is the small separate window.

1. **Start.** Run `StowLab.exe`. The log should say "Mouse hook installed".
2. **Edge.** In File Explorer, drag a file to the left or right edge of the screen. The shelf should appear at that edge. Drop the file on it.
3. **Other sources.** Same as test 2 from the desktop, from Chrome or Edge (an image, a link, some selected text), from Photos, from a file inside a `.zip` opened in File Explorer, and from Outlook (an attachment, and a whole email) if you have it.
4. **Things that must not show the shelf:**
   - moving a window by its title bar to the edge (check that Snap still works);
   - selecting text by dragging;
   - dragging a selection rectangle on the desktop.
5. **Shake.** Start dragging a file and shake the pointer left and right. The shelf should appear near the pointer's screen edge.
6. **Guess.** Tick "a drag starts (experimental guess)" and repeat tests 2–4. Does the shelf appear right away for file drags, and stay away for the things in test 4?
7. **Empty shelf.** Clear the shelf and start a drag, so the shelf shows up empty. Let go anywhere except the shelf. It should hide about 0.3 s later.
8. **No focus.** Type in Notepad, then drag a file onto the shelf and click an item. Notepad should keep the focus, and typing should still go into Notepad.
9. **Background.** Try Acrylic, Mica and Solid. Which one looks right? Are the corners rounded?
10. **Virtual desktops.** Press Win+Ctrl+D for a new desktop and Win+Ctrl+←/→ to switch. Is the shelf on every desktop?
11. **Full screen.** Play a video in full screen in a browser. Does a drag bring the shelf up on top of it?
12. **Two displays** (PC only, ideally with different scaling). Does the shelf come up crisp, at the right size, at the edge of whichever display the pointer is on?
13. **Focus box.** Click the box at the bottom of the shelf, type something, then press Esc. Typing should land in the box, and Esc should hand focus back to the app you were in.
14. **Dragging out:**
    - Drag an item into a folder on the same drive. It should copy: the log should say the original is still in place.
    - Do it again, holding Shift during the drag. It should move.
    - Ctrl-click two items and drag both out at once.
    - Drag items into a browser (for example a Gmail attachment), Outlook or Mail, Discord or Slack, and the desktop.
    - Is there a picture under the pointer while dragging out, or only the cursor?
15. **Other drag-out mode.** Switch "Dragging out" to the other option and repeat the first two parts of test 14.
16. **Virtual files back out.** Drag items that came from a browser or a zip (they're in the folder that Open Promised Folder shows) back out to the desktop.

Then press **Copy Log** and paste it to Claude, along with anything you saw that the log can't know (looks, flicker, what Snap did).

### Phase 1: skeleton
Tray icon with a menu (Show/Hide Shelf, Clear Shelf, Quit), one copy running at a time, no taskbar button, refuses to start on Windows 10.

### Phase 2: the shelf
Drop in files, folders and virtual files; real thumbnails; drag several items out; copy by default and Shift to move; remove after a successful drop; basic right-click menu (Open, Show in File Explorer, Remove); the Promised folder cleanup.

### Phase 3: auto-appear
The mouse hook, the edge strips and shake to summon (and the "as soon as you drag" guess if Phase 0 shows it's reliable); hiding an empty shelf 0.3 s after a drag ends; docking rules and multiple displays.

### Phase 4: core features
Saving the shelf across restarts, the global shortcut, text, links and images, the Settings window, open at login, Space to preview, keyboard control.

### Phase 5: matching the Mac version
Stacks, reordering, pins, stack names, flicking items off, quick actions, screenshots, Send to, Narrator, the welcome card, the tray count. The Mac's `StowTests` are ported to MSTest (Microsoft's own test framework) along the way.

### Phase 6: shipping
Packaging, signing, the update checker, a GitHub release workflow, and possibly the Microsoft Store.

## Still to decide

- **How friends get it** (before Phase 6): a GitHub download (SmartScreen warns unless it's signed; Microsoft's Trusted Signing is about $10/month if you're eligible), the Microsoft Store (free for individual developers; Microsoft signs the app), or both.
- **Scope** (after Phase 4): full parity with the Mac, or stop and see how it feels.
