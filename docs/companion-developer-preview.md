# Companion developer preview

Open the generated Xcode workspace and select the **SchneeBarCompanionPreview** scheme after running `mise exec -- tuist generate`. Build and run explicitly on macOS 15 or later. This is not the normal SchneeBar app, not a release artefact, and not intended to run concurrently with SchneeBar or SchneeRunner.

- Quit regular Bar and Runner; launch the preview. Initially there is no preview status item or CPU acquisition.
- Click Start preview. An original geometric snow creature appears in one preview status item.
- Toggle host CPU and automatic/manual speed; test both consumers, CPU-only, character-only and both disabled.
- Test Freeze and system Reduce Motion. Sleep/wake, stop and close window; verify CPU and animation stop on no demand.
- Launch regular Bar while preview runs; preview should stop in response to the workspace notification. Do not rely on this check as an atomic process lock.
- Quit preview and launch normal Bar; its settings and icon must remain unchanged.

The new target is an unverified developer prototype. No user files, credentials, asset pack, notifications or login settings are read or migrated. No fan artwork. CI and real-Mac testing are required before production assembly.
