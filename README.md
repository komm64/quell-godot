# Quell Godot

Godot binding and demo project for Quell.

This repository contains the public Godot addon wrapper:

- `addons/quell` registers the `QuellRuntime` custom node.
- `scripts/` and `scenes/` contain the demo UI and risk graph.
- The proprietary analysis and mitigation implementation is expected at
  `addons/quell_core` during local development or commercial distribution.

The private core lives in `komm64/quell-core` and is intentionally not committed
to this repository.

## Install Private Core Locally

From this repository:

```powershell
.\tools\sync_private_core.ps1 ..\quell-core
```

That command copies `../quell-core/engines/godot/addons/quell_core` into
`addons/quell_core`. The directory is ignored by Git.

## Run Demo

```powershell
godot --path .
```

Without `addons/quell_core`, the demo opens with a missing-core notice. With the
private core installed, it runs the GPU `RenderingDevice` demo:

- full-size display output
- reduced Raw and After analysis textures
- Raw risk from the generated source texture
- measured After risk from re-analyzing the corrected texture
- configurable viewing distance and After target
- HUD graph for Raw, After, and mitigation strength

## Addon Use

Copy `addons/quell` into a Godot project and enable **Project > Project Settings
> Plugins > Quell**. For a functional commercial build, install the matching
private `addons/quell_core` package as well.

The public node-facing API is `QuellRuntime`. The detection, feedback controller,
GPU metric reducer, and mitigation compute shaders are private implementation
details supplied by `quell-core`.

## License

TBD for the public wrapper. The core implementation is proprietary.
