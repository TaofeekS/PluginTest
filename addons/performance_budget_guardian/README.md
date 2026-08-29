# Performance Budget Guardian addon

Copy this directory to `res://addons/performance_budget_guardian/`, enable **Performance Budget Guardian** in Project Settings > Plugins, and add a `PerformanceBudgetProbe` node to the scene to measure. The node also works when its script is attached directly, including headless runs.

The probe captures engine process/physics time and global memory/object/node monitors after a configurable warmup. It writes raw samples and summaries atomically to a safe `res://` path. It does not measure a project workload directly, perform cleanup assertions, access the network, or require Python or AI.

Because the probe accumulates raw samples during capture, static-memory growth includes probe storage overhead and cannot by itself prove a project memory leak. A memory budget can flag a regression between comparable captures, but comparisons should use the same measured-frame count and sampling interval.

Command-line overrides are `--pbg-profile`, `--pbg-warmup-frames`, `--pbg-measured-frames`, `--pbg-sampling-interval`, `--pbg-output`, `--pbg-run-id`, `--pbg-source-revision`, and `--pbg-auto-quit`. Value-bearing arguments use `--name=value`.

When upgrading the addon, replace the installed addon directory while the plugin is disabled and create a fresh capture with a new run ID. Do not change old capture metadata to claim a newer addon version: result files are evidence of the version that produced them.

To remove the addon, remove its probe nodes, disable the plugin, and delete only `res://addons/performance_budget_guardian/`.

Installing the addon is separate from enabling CI. For turnkey Windows CI, also commit the addon, keep an automatically starting probe in the measured scene, commit a schema-v2 profile budget, ignore `.performance-guardian/`, and call the repository's reusable workflow at an immutable Guardian commit SHA. It installs Godot, runs three isolated captures by default, validates them, applies the project budget, and uploads captures, logs, a manifest, and canonical gate JSON. AI investigation is optional and defaults to `never`; deterministic validation and budgets always decide the exit. See the root [consumer CI instructions](../../README.md#turnkey-ci-for-another-godot-project).
