# RoboMaster Aim Lab

A standalone RoboMaster auto-aim closed-loop simulation environment. Godot provides the 3D scene, UI, and virtual camera; motion, gimbal response, ballistics, and hit detection are computed by independent GDScript modules. No ROS, industrial camera, CAN bus, or serial port required.

Control signals, feedback, and raw camera frames are passed via local shared memory, allowing you to plug in your own C++, Python, or other-language auto-aim system. This repo only runs the simulation — it does not bundle a detection network, vision repo, or real-hardware drivers.

Original work is under the [MIT License](LICENSE) — commercial use, modification, and closed-source distribution are allowed with copyright/license notices preserved. Third-party assets are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). This project is not an official RoboMaster / DJI product.

## Documentation Map

- First run: "Startup" and "Quick Integration" sections below.
- Connecting your own auto-aim: [Integration Guide](docs/integration.md) — Python frame capture, C++/OpenCV adapter, intrinsics/extrinsics, threading tips.
- C++ detailed integration: [Build & Full Example](docs/cpp_integration.md) — file handshake, OpenCV, PnP, control readback, multithreading.
- Implementing your own client: [Full Protocol](docs/protocol.md) — fields, coordinates, clock, sequence numbers, image handshake, disconnect handling.
- Reproducing scenarios: [Config & CLI Reference](docs/configuration.md) — all config keys, defaults, and ranges.
- Swapping models/textures: [Model Notes](docs/models.md); licensing and sources: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Startup

The verified platform for running and IPC is **Linux x86_64**, Godot **4.7.2**, with an OpenGL-compatible rendering mode. Camera mode requires a graphics session and OpenGL drivers; pure control/ideal observation can run headless. Requires Git and Python 3 (control demo uses stdlib only); no ROS, CUDA, or OpenVINO needed.

```bash
git clone https://github.com/ForgetWW520/rm_aim_sim.git
cd rm_aim_sim
python3 tools/setup_godot.py
# Import textures and assets after first clone; not needed on subsequent runs.
./run.sh --headless --editor --import --quit
./run.sh
```

You can also open `project.godot` in the Godot editor, wait for asset import, then press F5. `run.sh` looks for Godot in order: `GODOT_BIN` env var, `godot`/`godot4` on PATH, then `.tools/godot` locally. **The Git repo does not include the engine binary**; the auto-download script only supports Linux x86_64 and requires access to GitHub Releases.

The download script pins the official version and verifies SHA256; it does not install system software. You can also download manually from the [Godot official site](https://godotengine.org/download/linux/) and point to it:

```bash
GODOT_BIN=/absolute/path/to/godot ./run.sh
```

The Chinese UI uses system fonts; on Linux, installing Noto CJK fonts is recommended.

## Quick Integration: Verify the Interface First, Then Add Your Algorithm

**Terminal 1** — start the graphical simulation with external control enabled:

```bash
./run.sh -- --remote
```

**Terminal 2** (from the repo root) — verify feedback and fixed-angle control, no firing:

```bash
python3 tools/control_demo.py --yaw=5 --pitch=3 --duration=3
```

Once actual yaw/pitch converge to the target values, verify raw camera frames separately. These two demos are both control clients — **they cannot occupy the same channel simultaneously**:

```bash
# Verify frame capture only — no NumPy/OpenCV needed, no gimbal control, no firing.
python3 tools/camera_demo.py --no-display --frames=30

# Optional: install display deps in a venv, then view the exact image your auto-aim will receive.
python3 -m venv .tools/camera-venv
.tools/camera-venv/bin/python -m pip install numpy opencv-python
.tools/camera-venv/bin/python tools/camera_demo.py
```

Press Q / Esc or Ctrl+C to exit the camera demo. `--no-display` only closes the client window — **the simulation still requires a graphics session**; simulation `--headless` produces no pixel output. The demos do not detect armor and do not constitute a complete auto-aim acceptance test.

C++ users can build the standalone example directly (requires OpenCV and nlohmann-json dev packages):

```bash
cmake -S examples/cpp -B .tools/cpp-demo -DCMAKE_BUILD_TYPE=Release
cmake --build .tools/cpp-demo -j2
.tools/cpp-demo/sim_client_demo --no-display --frames=30 --duration=10
```

For dependency installation, fixed-angle control, and integrating into your own project, see [C++ Integration Details](docs/cpp_integration.md).

When integrating your own project, the minimum changes are replacing two touch points — "camera input" and "gimbal communication":

```text
frame-*.raw + frame.json  →  same-frame image/pose/time  →  your detection/PnP/tracking/lead
                                                               ↓
state.json  ←  actual gimbal/muzzle velocity/stats  ←  sim  ←  command.json (yaw/pitch/fire)
```

For concrete code, calibration matrices, stream-loss protection, and acceptance order, see the [Integration Guide](docs/integration.md). Do not use `truth` or the ideal `camera.armors` as real image detection results.

## Static Target Validation (Do This First)

1. Default view is first-person; the target vehicle center is **4 m** in front of the gimbal world origin, with translation and spin disabled.
2. Hold **F** or "Hold Track" and wait for the gimbal to lock onto the armor.
3. Continue holding F, then also hold **Space** or "Hold Fire" — watch the hit counter and green impact points.
4. Press **V** to switch to third-person; right-click-drag to orbit, scroll to zoom. The gimbal camera preview is always shown in the top-right.
5. Enable translation and spin, set speeds — parameter changes take effect immediately with no Apply button.

While F is held, tracking is continuous; releasing it holds the last aiming angle. The built-in assist reads ground-truth target data directly, computes gravity drop, translation lead, and rotation lead, switches targets by armor facing, and executes via normal gimbal response — it does not auto-fire. Use this to verify simulation functionality first; you can disable the assist after connecting your external auto-aim.

**Keyboard shortcuts:** Arrow keys adjust yaw/pitch. Space fires. P pauses/resumes. R resets the current round. V toggles view. Hold F for continuous tracking. Pressing Space/F inside a number input field confirms the value and exits edit mode, then immediately fires/tracks; arrow keys still edit while a field is focused. Changing parameters preserves simulation time, statistics, projectiles in flight, and gimbal state — only clicking Reset or pressing R clears the round. Reset does not happen automatically. Pause preserves statistics and cancels pending fire commands. When external auto-aim control is active, local track and fire do not override external commands.

## Target Vehicle, Robot Types, and Models

- Target vehicle translation and spin can each be toggled independently; translation speed, acceleration, direction, travel range, and angular velocity are all configurable.
- Translation direction is defined in world space; half-travel is the maximum offset from the configured center. For example, half-travel 1.5 m = 3 m total stroke. Changing motion parameters at startup or runtime causes acceleration from rest, deceleration to zero near endpoints, then reversal; short strokes automatically use a triangular velocity profile that never reaches the set max speed. Immediate changes do not move the trajectory center; positions outside the new range are clamped to the boundary.
- Presets: Infantry 3/4/5, Hero 1, Sentry 7 — each switchable between red and blue. Hero uses large armor (**235 × 127 mm**); all others use small armor (**140 × 125 mm**), matching [official armor module specs](https://www.robomaster.com/en-US/products/components/detail/2614).
- Default light bar center spacing: large armor 230 mm, small armor 135 mm; light bar length 56 mm. These are the visual keypoint geometry values, configured separately from the overall module dimensions.
- All built-in armors use downloaded real-pattern textures, not font-generated numbers. The Sentry's logical number is 7 and uses a turret pattern. Panels sample a black background from the corresponding texture using the same unlit color; assets and sources are listed in [Model Notes](docs/models.md).
- The built-in blackboard uses a chamfered-corner and side-slot-channel outline; light bars have an armor-only faction-colored local halo that turns off when the bar is out, without changing projectile material, light bar geometry, or hit zone. First-person and camera preview share the same single 3D render pass.
- All presets show only four armor plates — no chassis mesh and no hidden chassis collision. The four armors translate and rotate around a shared center for auto-aim testing.
- Per the 2026 fabrication spec figures 3-16/3-17: black panel width is 135 mm (small) / 230 mm (large); including side lights the outer widths are 140/235 mm, heights are 125/127 mm. Panels tilt inward 15°. Light bar, module outline, and approximate hit zone are configured separately; armor panels can be replaced with GLB/glTF.
- Four armors are mounted front/back/left/right, 90° apart, with the two center-lines perpendicular and intersecting at the shared center. The "Armor Extension" slider collapses left and expands right; default **550 mm** for all types, maximum **600 mm** (project setting). This value is the rotation envelope diameter — including panel body, side lights, thickness, and tilt angle — guaranteeing the horizontal envelope at any rotation angle never exceeds the limit. It is not the center-to-center distance between facing armors. The minimum value is computed dynamically from armor dimensions and height offset, with a 1 mm geometric clearance, conservatively ensuring adjacent modules stay behind each other's front plane to avoid interpenetration and occlusion.
- "Reference armor bottom edge" and "armor height offset between the two groups" use sliders that take effect immediately. Per [2026 Fabrication Spec V1.3.0 §3.6 S154/S155](https://bbs-web-static.robomaster.com/715e2519e5384666a5d13edda17c6b831770696773838/RoboMaster%202026%20%E6%9C%BA%E7%94%B2%E5%A4%A7%E5%B8%88%E9%AB%98%E6%A0%A1%E7%B3%BB%E5%88%97%E8%B5%9B%E6%9C%BA%E5%99%A8%E4%BA%BA%E5%88%B6%E4%BD%9C%E8%A7%84%E8%8C%83%E6%89%8B%E5%86%8CV1.3.0%EF%BC%8820260209%EF%BC%89.pdf#page=74): bottom-edge height difference between any two armors ≤ 100 mm; bottom edge > 0 mm and ≤ 400 mm above ground. The UI preserves a 1 mm ground clearance and dynamically limits the slider based on the other group's height; internally, center position is computed from module height and tilt angle. Defaults: reference group bottom edge **200 mm**, height offset **−100 mm**, second group bottom edge **100 mm**. Even-numbered armors use the reference center height; odd-numbered armors add the height offset. The sliders adjust the test mounting posture and do not simulate an automatic lift mechanism.
- Effective hit width/height is configured separately from module outline and light bar geometry. Default rectangular hit zones: small armor 135 × 125 mm, large armor 230 × 127 mm — these are adjustable simulation approximations and are not an authoritative official hit-zone specification.
- Model files change display only, not hit zones. Built-in textures are determined by robot type; light bar color is determined by faction. Custom armor models must supply their own patterns and follow the `Team`/`Lightbar` node naming convention for automatic color-switching and light-out behavior.

## HP and Damage

Defaults follow the **3v3 combat match** of the [2026 RMUL University League Rules V1.2.0](https://bbs.robomaster.com/wiki/20204847/809872), no buff state:

| Target | Default HP | Armor |
|---|---:|---|
| Hero 1 | 350 HP | Large |
| Infantry 3/4/5 | 350 HP (HP-priority mode) | Small |
| Sentry 7 | 400 HP | Small |

Power-priority Infantry is 300 HP; RMUL infantry combat is 200 HP — set via the HP input field. The launcher is fixed at **17 mm projectiles, 20 HP base damage per shot**; damage is editable. The 42 mm projectile (200 HP base) from the rules is not yet implemented; switching to the Hero target only changes the target's appearance and parameters.

Armor hits deduct HP, floored at 0; the final shot only counts actual HP deducted. At zero HP the light bars go dark, the ideal camera stops outputting armor keypoints, and the target stays at its death position and angle. Translation/spin toggles and speed settings are preserved; after reset HP is restored and motion resumes. Geometric hits still count toward hit rate but no longer deduct HP or count kills. The current simulation does not model full combat death/power-off, respawn countdown, buffs, shot heat, or real armor detection intervals and trigger thresholds.

When a living armor plate is hit by a projectile, only that plate's light bar and halo go dark for **50 ms simulation time**, then restore to faction color (blue→off→blue, red→off→red). Consecutive hits restart the timer from the last hit; the timer freezes when paused; ground hits and misses do not trigger it. Panel and number textures do not disappear; first-person, third-person, camera preview, and shared-memory images all reflect this simultaneously; during the dark period that plate does not output ideal keypoints. A lethal hit keeps all bars permanently dark. The 50 ms is a project display parameter, not an official detection interval; it does not change collision scoring or HP deduction rules.

The HP field shows current HP at rest; editing it sets both current HP and maximum HP simultaneously, takes effect immediately, and can restore light bars. Switching robot type resets to the type's default HP; both actions preserve cumulative statistics. Pressing R restores the configured HP and clears the round statistics. Restoring HP or resetting clears any pending hit-flash state. Config key `target.max_health=-1` means use the robot-type rule HP; a non-negative integer overrides it; 0 means the target starts dead.

## Gimbal, Projectiles, and Statistics

The gimbal uses a second-order servo model with velocity and acceleration limits, accepting angle, angular velocity, and angular acceleration inputs. Control commands specify target values; camera, feedback, and muzzle use actual pose. This is a fixed-position two-axis gimbal; the initial version does not simulate friendly chassis motion.

When the fire enable is continuously true, trigger events are generated at the set rate of fire; after the fire delay, the projectile is launched using the **actual muzzle position and direction at the moment of departure**. Releasing `control`, losing connection, or pausing cancels pending departure events; releasing `fire` stops new triggers, but already-accepted triggers still complete.

Projectiles are displayed at the official 17 mm fluorescent projectile nominal diameter of 16.8 mm, with a fixed fluorescent-green sphere and trail; hit detection still uses a gravity-affected point mass and analytic parabola. Continuous intersection with moving/rotating armor is solved in sub-steps of ≤ 1 ms / ≤ 0.005 rad rotation angle; only the outer face of active armor scores. No chassis collision; each projectile scores exactly once against the earliest armor or ground hit. Ground hits, out-of-bounds clears, and lifetime timeouts count as misses. The trail shows the last 18 ms of flight trajectory. [Official projectile specs](https://www.robomaster.com/zh-CN/products/components/detail/2571)

- `fired`: number of projectiles that have actually departed — pending departures not counted.
- `resolved`: projectiles with a final result — armor, ground, out-of-bounds clear, timeout.
- **Hit rate = armor hits / resolved** — projectiles still in flight are not yet in the denominator.
- Always satisfies `fired = resolved + in_flight`; alongside hit rate, the display also shows shots fired, in-flight count, hits/sim-second, and time of first hit.
- `damage`: cumulative actual HP deducted. `kills`: number of times HP went from positive to 0. Damage is determined at departure; editing damage does not affect already-departed projectiles.
- Miss projectiles are cleared and scored as `expired` once they exit the bounding volume that contains the full target travel range and armor dimensions; projectiles that could still hit a distant target are not prematurely cut off.
- After hitting armor or ground, projectiles reflect off the collision normal with velocity attenuation and show a bounce effect for up to 0.8 sim-seconds, with continuing low-amplitude bounces on the ground. No fixed floating impact-point spheres are generated. Flight, trail, and bounces all use an unlit fluorescent-green material to avoid washing out. Bounces are a visual effect only — no re-scoring or re-damage. The attenuation coefficient is a simulation display parameter, not an official value. Cleanup preserves round counts and events.
- Exported JSON contains cumulative statistics, current round config, and the last 128 fire/collision events; camera PNGs and export results are placed in the gitignored `captures/` directory.

The initial version does not simulate air resistance, muzzle velocity variance, dispersion, or motion blur. The camera provides only a simplified exposure appearance. Hit rate is for algorithm and interface validation and does not directly correspond to real-hardware hit rate.

## Configuration and Integration

Default config is in [configs/default.cfg](configs/default.cfg) using Godot ConfigFile format. UI parameters take effect immediately; the current active config is saved to `user://last_scenario.cfg` (absolute path shown in the UI). The saved HP is the configured HP, not the current combat HP.

```bash
./run.sh -- --config=/absolute/path/to/scenario.cfg
./run.sh -- --config=res://configs/combined.cfg
./run.sh --headless -- --remote
python3 tools/control_demo.py --yaw=0 --pitch=0 --fire --duration=5
```

Provided presets: `translate.cfg` (translation only), `spin.cfg` (spin only), `combined.cfg` (translation + spin). Config files only need to specify parameters you want to override; all other fields inherit defaults.

Only same-machine, same-user processes on Linux are supported; no TCP/UDP ports are opened. Graphical mode requires "Local Auto-Aim Control" to be enabled; headless mode uses `--remote`. Both simulation `[ipc].channel` and vision `[sim].channel` default to `default`; data is exchanged via `/dev/shm/rm_aim_sim_default/`. Only one simulation and one control client are allowed per channel. `control_demo.py` is a send/receive interface example; angle parameters are in degrees and are internally converted to the protocol's radians.

Feedback includes actual pose and quaternion, muzzle velocity, simulation time, ideal armor keypoints, full target ground truth, cumulative statistics, and recent events. Ground truth is for scoring and debugging and should be kept separate from the observation data your actual auto-aim uses. Protocol, coordinate conventions, and clock conventions are in [docs/protocol.md](docs/protocol.md).

The first-person main view shows raw rendering unaffected by the exposure slider; the top-right camera preview shows the post-exposure image, which matches the pixels your auto-aim receives. Both share a single 3D render pass — only the camera output adds a 2D processing step.

The virtual camera defaults to 1440×1080, 45° vertical FOV, matching `configs/sim.conf` in the vision repo. The left-side "Camera" panel lets you select common resolutions or type custom width/height and FOV directly, taking effect immediately while preserving round state and statistics. The "Camera Exposure Gain" slider ranges from 0–4×, default 0.4×; below 1× reduces exposure, 0 = full black, above 1× increases exposure. It only affects the camera preview and shared-memory image — scene lighting is unchanged — and is saved as `[camera].brightness_gain`. The simplified imaging model separates built-in light bar self-emission from background, then applies exposure and saturation clipping: at 0.1× the background and numbers darken significantly while light bars can still be bright. This is an exposure appearance approximation; it does not model optical HDR calibration, noise, or motion blur. After changing resolution or FOV, the auto-aim side's resolution and intrinsics must also be updated; no special coordinate transformation is applied to auto-aim input. Shared memory provides uncompressed RGB/RGBA and same-frame pose, time, and calibration on request; the vision client mmaps and converts to its own BGR image — no JPEG encode/decode:

```bash
./run.sh -- --config=res://configs/vision.cfg --remote
# Optional: if your rm_vision already has a matching adapter entry, build and run from its root per its docs:
./build/auto_aim_sim configs/sim.conf
```

`auto_aim_sim` (and multi-threaded `mt_standard_sim`) and `--ideal` above are entry points/options of an external vision project — **they are not provided by this repo** and are not prerequisites for running the simulation. Ideal keypoints are for backend diagnostics only and can be used with headless simulation; they are filtered by facing angle and FOV only, with no per-pixel occlusion detection from any external model.

## Verification

```bash
./run.sh --headless --script res://tests/run_tests.gd
python3 tests/integration.py --godot "$PWD/.tools/godot"
./run.sh --script res://tests/ui_smoke.gd -- --no-ipc
./run.sh --script res://tests/ui_smoke.gd -- --no-ipc --camera-only
```

1. Runs standalone simulation core checks.
2. Actually launches headless simulation and exchanges state and commands via shared memory, verifying the full chain: command → actual pose → departure → hit → HP deduction → statistics, plus disconnect fire-stop.
3. Opens a graphics window and checks robot-type textures, red/blue switching, height sliders, pause, fire-after-number-input, continuous tracking, green bounces, and camera readback, then auto-exits.
4. Verifies camera resolution, brightness gain, and preview/shared-memory pixel consistency only — no keyboard focus dependency.

Integration tests use an isolated temporary channel and do not occupy the default channel.

## Directory Structure

```text
scripts/simulation.gd     Standalone motion, gimbal, projectile, collision, and scoring
scripts/aim_assist.gd     Built-in ground-truth tracking assist and ballistic lead
scripts/bridge.gd         Local control mailbox, sequence validation, and disconnect handling
scripts/camera_stream.gd  Publishes raw shared-memory images and same-frame metadata on request
scripts/local_ipc.gd      tmpfs atomic publishing and simulation instance mutex
scripts/world_view.gd     3D display and camera texture reuse
scripts/visual_assets.gd  Replaceable GLB/glTF loading and size normalization
scripts/presets.gd        Robot types, numbers, and red/blue configuration
scripts/main.gd           Scene entry point, parameter UI, and manual controls
configs/                  Reproducible scenario configs
assets/models/            Retained historical reference chassis (not currently loaded)
assets/third_party/       Upstream licenses and pinned-version source list
tests/                    Core, shared-memory closed-loop, and graphics acceptance tests
tools/                    Runtime environment, model download, and control client examples
```

## Known Limitations

- IPC is Linux same-machine, same-user only; no ROS topics, CAN, serial, or cross-machine TCP/UDP.
- The default target is four armor plates, not a full robot; no chassis collision, full occlusion, friendly chassis motion, air resistance, dispersion, camera noise, or motion blur.
- Camera exposure is a simplified appearance model; the gimbal is a second-order model with rate/acceleration limits, not an identified real-hardware model. The first-person main view is unaffected by exposure; the top-right camera preview is what the auto-aim actually receives.
- Collision and time use fixed stepping, but process scheduling, rendering, readback, and copy are not hard real-time. Reversal prediction, detection stability, control feedforward, etc. remain the responsibility of the connected algorithm.
- This project is for interface and algorithm debugging; it does not guarantee any detection model will directly fit the simulation appearance, nor that simulation hit rate equals real-hardware hit rate. Follow the [acceptance sequence](docs/integration.md#验收顺序) to verify communication, detection, pose estimation, tracking, control, and firing separately.

## Reporting Issues

Please open a [GitHub Issue](https://github.com/ForgetWW520/rm_aim_sim/issues) and include your Linux/Godot version, startup command, scenario config, logs, and expected vs. actual behavior. For camera issues, attach the image your auto-aim received plus the resolution, K matrix, and `sim_time` from `frame.json`. For control issues, attach the issued commands and actual pose. Remove personal paths, tokens, and other sensitive information before posting.
