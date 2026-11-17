# Companion developer preview

Open the generated Xcode workspace and select the **SchneeBarCompanionPreview** scheme after running `mise exec -- tuist generate`. Build and run explicitly on macOS 15 or later. This is not the normal SchneeBar app, not a release artefact, and not intended to run concurrently with SchneeBar or SchneeRunner.

- Quit regular Bar and Runner; launch the preview. Initially there is no preview status item or CPU acquisition.
- Click Start preview. An original geometric snow creature appears in one preview status item.
- Toggle host CPU and automatic/manual speed; test both consumers, CPU-only, character-only and both disabled.
- After native CI and the manual acceptance checks below, test the draft image picker: choose a permitted local PNG, APNG, GIF or WebP, restore the original geometric image, and try corrupt and oversized inputs. Only one worker may execute. Stop, hide, sleep or quit while selecting/decoding; stale results must not publish. A successful selection is in-memory only; Stop/restart restores the built-in image. No file path is shown in the UI. No pack or persistent import.
- Test Freeze and system Reduce Motion. Sleep/wake, stop and close window; verify CPU and animation stop on no demand.
- Attempt to start while regular Bar, packaged Runner or a second bundled preview is running; starting must be refused. Launch either packaged app while preview runs; preview should stop on the workspace notification. Repeat with a launch while sleeping and verify wake-time rechecking. The known bundle IDs are `dev.lamy.schneebar`, `io.github.Lamy210.SchneeRunner` and `dev.lamy.schneebar.companion-preview`. The current process is excluded. Unbundled development executables, simultaneous launches and altered bundle IDs cannot be reliably detected by this cooperative check; it is not an atomic process lock.
- Quit preview and launch normal Bar; its settings and icon must remain unchanged.

The preview baseline passed macOS CI 43996910174. The new image-picker revision is an unverified developer prototype. Explicitly selected images are read only for this preview; credentials, asset packs, notifications and login settings are not read or migrated. Users must have permission to use an image; no bundled fan artwork. Validate sandbox/selected-file permission behavior, security-scope balancing, APNG/WebP and truncated/partial frame fixtures, old-plus-new peak memory, and actual macOS panel/lifecycle behavior before accepting the picker for broader use. No release artifact or production assembly.

## Draft local notification preview

Opt in with "Listen to local Runner events" only after starting the isolated preview. Use the existing Runner CLI event wire format without launching the Runner app. Untrusted local events only affect the character; no GitHub or command execution. Test with automatic CPU speed off, state expiry, hide/reshow, sleep/wake, Stop and relaunch, malformed and oversized input, background delivery, and a controlled sender storm. Distributed notifications may be dropped or delayed. The new transport remains a draft; actual two-process/real-Mac acceptance is not yet established. No user notification schedules are migrated.

## Draft persistent character library

After explicit Start, the preview uses its fixed Application Support child `dev.lamy.schneebar.companion-preview-packs-v1`, not Runner or shipping Bar storage. Only the final directory is created (0700). Start restores the saved UUID after validation. Import saves a copy without selecting it; select explicitly to save the choice. "Session default" and single-file images are transient; "Use built-in" clears persistent choice. "Restore saved" revalidates it. Stop/hide/sleep fence UI publication; a started durable operation may commit even after Stop. Restart is blocked until the worker exits. No trash/purge/recovery UI yet. Real picker, root permissions, sleep/quit, accessibility and memory acceptance remain required.

## Draft trash and recovery controls

Use a pack's trash button, then confirm the full UUID. Trash and stage IDs are visible in Trash and recovery. Restore never selects; permanent delete and stage/pending discard require explicit confirmation. Selection is cleared on the store before moving a selected pack, while the preview switches to built-in before starting the worker. If the move fails, restore explicitly to reconcile the persisted choice. Unknown entries are not eligible for automatic cleanup. The Quit button is disabled during a library operation (OS termination can still interrupt it). Check stale dialogs after hide/sleep/stop, failed rename/unsafe content, restart and source preservation on a real Mac.