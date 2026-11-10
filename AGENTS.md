# Repository Ground Rules

- This repository is the public Godot wrapper/demo. It must load or sync the proprietary core from `C:\Users\komm64\Projects\quell-core\engines\godot\addons\quell_core`.
- Do not implement analyzer, solver, mitigation-policy, feedback-controller, GPU pipeline, or core shader logic directly in the wrapper. Put those changes in `quell-core` first, then run `tools\sync_private_core.ps1 C:\Users\komm64\Projects\quell-core`.
- Wrapper code may own demo UI, k64-io actions/status, launch/test harness wiring, and wrapper-specific presentation.
- `C:\Users\komm64\Projects\quell` is an archived/legacy prototype wrapper, not the active Godot wrapper.
- CurrentFrame mitigation control may read only After/output history plus the current Raw frame. Rolling Raw history must not influence mitigation decisions; enforce this in `quell-core`, not with wrapper-side workarounds.
- Before reporting Quell visual or mitigation fixes as done, inspect at least one real captured image from the visible/downstream output buffer, not only logs or numeric status.

## Performance policy (decided 2026-07-26)

Quell is a protection product against photosensitive seizures, not a game, so the
global "Steam top 95% at 60fps" target spec does not apply.

- Safety (detection accuracy and suppression quality) comes first; performance follows it.
- It is acceptable if Quell does not run well on a Surface Pro 7 class iGPU. Do not
  lower detector or suppressor quality to reach 60fps there.
- Measuring on the SP7 is fine as a regression signal, but it is not a release gate.
  Performance requirements stay undefined until they are specified separately.
