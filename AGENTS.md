# Repository Ground Rules

- This repository is the public Godot wrapper/demo. It must load or sync the proprietary core from `C:\Users\komm64\Projects\quell-core\engines\godot\addons\quell_core`.
- Do not implement analyzer, solver, mitigation-policy, feedback-controller, GPU pipeline, or core shader logic directly in the wrapper. Put those changes in `quell-core` first, then run `tools\sync_private_core.ps1 C:\Users\komm64\Projects\quell-core`.
- Wrapper code may own demo UI, k64-io actions/status, launch/test harness wiring, and wrapper-specific presentation.
- `C:\Users\komm64\Projects\quell` is an archived/legacy prototype wrapper, not the active Godot wrapper.
- CurrentFrame mitigation control may read only After/output history plus the current Raw frame. Rolling Raw history must not influence mitigation decisions; enforce this in `quell-core`, not with wrapper-side workarounds.
- Before reporting Quell visual or mitigation fixes as done, inspect at least one real captured image from the visible/downstream output buffer, not only logs or numeric status.
