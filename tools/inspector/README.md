# Mach inspector, GPU tracker and shader linting

Tools to see how a Mach program is structured: modules, schedules, objects, GPU objects and how
they relate. They also catch GPU API mistakes at compile time where possible, and at runtime with
messages pointing at your code.

| Piece | What it does | Where | When it's on |
|---|---|---|---|
| `mach.wgsl` | Compile-time WGSL reflection: derives and checks bind group layouts, bind groups, host structs, entry points and vertex buffers against a shader | `src/wgsl.zig` | always (comptime only) |
| GPU tracker | Records every GPU object's lifetime, refcount, creation/release site and relations; validates bind groups and pipelines against layouts and shader reflection; reports over-releases, use after release and leaks | `src/sysgpu/track.zig` | `-Dgpu_track` (Debug default) |
| `mach.dvx.Inspector` | Serves live snapshots of modules, systems, schedules, dataflow, threads, objects and the tracker's GPU objects to the tool, Tracy-style | `src/dvx/Inspector.zig` | `-Dinspector` (Debug default), recording only while a viewer is connected |
| `mach-inspector` | Interactive graph viewer built with Mach (gfx.Sprite + gfx.Text) that connects to the running app. Not part of the runtime | `tools/inspector/` | `zig build inspector` |
| `lint-gpu` | Static check that GPU resources acquired in a function get released | `src/dvx/gpu_lint.zig` | `zig build test` / `zig build lint-gpu` |

## Compile-time shader checks (`mach.wgsl`)

```zig
const shader = mach.wgsl.Shader("sprite.wgsl", @embedFile("sprite.wgsl"));

// Generate the layout from the shader...
const layout = device.createBindGroupLayout(&shader.layoutDescriptor(0, "my layout"));
// ...or check a hand-written one.
comptime shader.checkLayout(0, &my_entries);

// Typed bind group: one field per shader variable of @group(0). A missing or wrong-typed field
// is a compile error; binding numbers and element sizes come from the shader.
.entries = &shader.bindGroupEntries(0, .{
    .uniforms = .{ .buffer = uniforms },
    .spriteSampler = sampler,
    .spriteTexture = view,
}),

comptime shader.checkHostType("uniforms", Uniforms); // offsets, sizes, padding
.entry_point = shader.vertexEntry("vertMain"),       // must exist and be @vertex
comptime shader.checkVertexBuffers("vs", &buffers);
comptime shader.checkColorTargets("fs", 1);
```

Errors read like this:

```
error: sprite.wgsl:92: @group(0) @binding(4) `spriteSampler`: sampler, used by fragment
         error: the fragment stage uses it, but layout entry 4 is only visible to .{ .vertex = true }
         fix: .visibility = .{ .vertex = true, .fragment = true }
```

`gfx.Sprite` and `gfx.Text` use these checks on their own shaders.

## Runtime checks (GPU tracker)

These hold for every shader, including ones built at runtime: sysgpu's own WGSL compiler
provides the reflection. Problems are logged once per call site as `error(gpu)`, pointing at
your code:

```
error(gpu): layout_mismatch: pipeline 'test pipeline': shader 'test.wgsl' uses @group(0) @binding(2) `t` (sampled texture), but @group(0)'s bind group layout 'test layout' has no entry 2
  at examples/sprite/App.zig:132: setupPipeline
error(gpu): over_release: texture 'test tex' released more times than it was acquired/referenced (already released in frame 0); this release was skipped
  at examples/sprite/App.zig:135: setupPipeline
  created at examples/sprite/App.zig:110: setupPipeline
  released at examples/sprite/App.zig:134: setupPipeline
```

The tracker checks for:

* over-release, which is skipped instead of double-freeing
* use after release
* leaks: objects still alive when the device is released, grouped by creation site
* bind groups vs. their layout: missing or extra bindings, wrong resource kinds, buffers or
  textures without the needed usage flags, out-of-range buffer bindings
* pipelines vs. their shaders' reflection: bindings missing from the layout, wrong kinds, wrong
  visibility
* draws: missing bind groups, or bind groups whose layout doesn't match the pipeline's

When a problem would make the backend fail, such as Metal's `buffer(1337)` shader compile
error, it panics with `mach: invalid render pipeline '...'` after logging the explanation.

Source locations are best effort. Zig's debug info on macOS only resolves the innermost inline
frame, so the tracker looks around sysgpu's inline API wrappers for your code. Each site also
names its caller.

## The live inspector

It works like Tracy:
- **The app serves:** a Debug build with `mach.dvx.Inspector` registered listens on `127.0.0.1:8087`, or the next free port up to 8096. It records nothing until a viewer connects. While one is connected, it streams a snapshot every second.
- **The tool connects:** run `zig build inspector`. It finds the running app, shows it live, and reconnects when you restart the app.

1. Register `mach.dvx.Inspector` in your `mach.Modules`, and schedule:
   - `.{ mach.dvx.Inspector, .init }` in your init
   - `.{ mach.dvx.Inspector, .tick }` on the thread that mutates your objects (usually the app tick)
   - `.{ mach.dvx.Inspector, .deinit }` on exit

   See `examples/sprite`.
2. Run your app (a Debug build, or `-Dinspector=true`).
3. Run `zig build inspector`.

The tool can also act on the app:
- Select a schedule in the Systems view and click its bool params, such as conditions, to toggle them in the running app.
- `R` requests a snapshot now.
- `W` saves the current snapshot as a capture (`mach-capture-<n>.json`). Open it later, with no app running, with `zig build inspector -- mach-capture-<n>.json`.

From a project that depends on Mach:

```zig
const run_inspector = b.addRunArtifact(mach_dep.artifact("mach-inspector"));
run_inspector.addPassthruArgs();
b.step("inspector", "Inspect the running app").dependOn(&run_inspector.step);
```

### Views

* **1 Systems**: schedules → their entries (numbered, with conditions); systems → the modules they read, write or call (`mach.Mod`); schedule values (`ctx.schedule.put/get`, recorded while the tool is connected; `mach.Require`) → who puts and who reads them.
* **2 Objects**: modules → `mach.Objects` lists (live/capacity) → objects → the objects they reference by ID (e.g. `.window`, `.render_list`), parent/child relations, and the GPU objects held in their fields (CPU → GPU).
* **3 GPU**: textures → views → bind groups → pipelines; bind group layouts → pipeline layouts → pipelines; shaders → pipelines; which bind groups each pipeline is drawn with. Objects the app released but the backend keeps alive are labelled "kept alive by #N". Problems are red.
* **4 Lifetimes**: a bar per GPU object from the frame it was created to the frame it was released (open bars are still alive), then every creation site with created/released/alive counts. Per-frame objects that pile up are flagged as leaks.
* **5 Threads**: threads → the systems they run → the `mach.Objects` lists those read and write, with the locks held: the list's own lock and `mach.Core`'s render lock, which the app thread holds while it snapshots and the render thread holds while it renders. Likely races are red: a write on one thread and an access on another, overlapping in time, with no lock covering both.
* **6 Timeline**: what each thread ran in the last 50 ms.

### Controls

Drag the background to pan. Scroll or pinch to zoom. Click a node for its details (sites, refcount, memory, uploads, layout entries, shader bindings, connections, schedule params). Drag a node to move it; positions persist across updates.

Keys:
- `1`–`6`: switch views
- `G`: layout, either gravity (columns from left to right, arranged by a GPU force simulation so related nodes line up) or plain columns
- `C`: coloring, by type or by connected component
- `F`: fit the view
- `H`: show released objects
- `P`: problems panel (click a problem to jump to its object)
- `L`: relayout
- `R`: request a snapshot
- `W`: save a capture
- `S`: export SVG
- `Esc`: deselect
- Arrows pan; `+`/`-` zoom.

## Snapshot format

`version`, `modules[]` (systems with params/entries, `lists[]` with objects), `dataflow[]` and
`gpu` (`objects[]`, `edges[]`, `sites[]`, `problems[]`); see `tools/inspector/Model.zig`. It's
the data model a future editor or pipeline builder could build on.
