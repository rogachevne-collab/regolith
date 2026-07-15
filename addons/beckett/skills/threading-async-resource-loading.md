# Threading & async resource loading - stutter-free loads and safe parallelism

> Frame hitches on level change come from `load()` blocking the main thread. Godot ships three ladders: `ResourceLoader.load_threaded_*` (async file loads - use this first), `WorkerThreadPool` (fan-out compute), and raw `Thread`/`Mutex`/`Semaphore` (long-lived workers). The iron rule everywhere: worker threads never touch the scene tree - hand results back via `call_deferred`.

## Version note
- Server runs **4.6.2**; `load_threaded_*`, `WorkerThreadPool`, `Thread`, and the thread model setting all exist since **4.0** (floor 4.2 holds). `ResourceLoader.load_threaded_request(path, type_hint, use_sub_threads, cache_mode)` signature is stable across 4.x. Confirm with `describe_class class=ResourceLoader`.

## Async resource loading (the 90% case)
```gdscript
func start_level_swap(path: String) -> void:
    ResourceLoader.load_threaded_request(path)          # returns immediately

func _process(_dt: float) -> void:
    var progress: Array = []
    match ResourceLoader.load_threaded_get_status(level_path, progress):
        ResourceLoader.THREAD_LOAD_IN_PROGRESS:
            bar.value = progress[0] * 100.0             # 0..1
        ResourceLoader.THREAD_LOAD_LOADED:
            var scene: PackedScene = ResourceLoader.load_threaded_get(level_path)
            get_tree().change_scene_to_packed(scene)
        ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
            push_error("load failed: " + level_path)
```
- `load_threaded_get()` on a still-loading resource BLOCKS until done - poll status first if you need the frame back.
- `use_sub_threads=true` parallelizes inside one load (textures of a scene); it can reorder dependency loads - leave false unless measured faster.
- Instantiate is NOT free either: a huge `PackedScene.instantiate()` still hitches. Split levels into chunks, or instantiate over several frames.

## WorkerThreadPool (fan-out compute)
```gdscript
var task := WorkerThreadPool.add_task(heavy_func)            # one job
WorkerThreadPool.wait_for_task_completion(task)
var group := WorkerThreadPool.add_group_task(per_index_func, count)  # parallel-for
WorkerThreadPool.wait_for_group_task_completion(group)
```
- Sized to CPU cores, shared with the engine. NEVER `wait_for_*` from INSIDE a pool task on another pool task - that can deadlock the pool. Chain by submitting the follow-up from the completion instead.

## Raw Thread / Mutex / Semaphore (long-lived workers)
```gdscript
var thread := Thread.new()
thread.start(_worker)          # func runs off-main
# ... signal it work via a Semaphore, protect shared state with a Mutex ...
thread.wait_to_finish()        # ALWAYS join before the owner leaves the tree
```
- Pattern: worker computes, then `node.call_deferred("apply_result", data)` or `callable.call_deferred()` - the deferred call runs on the main thread where the tree is safe.

## What is thread-safe, what is not
- **Never from a worker thread:** any scene-tree access (`add_child`, `get_node`, `queue_free`), physics space queries while the physics step runs, anything `@tool`-editor.
- **Safe from workers:** pure math on your own data, `ResourceLoader.load` (resources are fine to LOAD off-main; ADDING them to the tree is not), building `Mesh`/`Image` data, servers (`RenderingServer`, `PhysicsServer3D`) via their thread-safe APIs when `call_deferred`-handed.
- Godot 4 removed most implicit locking: two threads mutating one `Array`/`Dictionary` is a data race - guard with `Mutex`.
- `rendering/driver/threads/thread_model` = Multi-Threaded moves rendering off-main (needs restart; test on target platforms - it changes timing bugs from "never" to "sometimes").

## Common traps
- **`load_threaded_get` without a prior `load_threaded_request` for that exact path returns null/fails.** Paths must match exactly, including `res://`.
- **The progress array only fills while IN_PROGRESS.** A cache-hit load jumps straight to LOADED with progress `[]` - handle both.
- **Freeing a node whose worker thread is still running** then touching `self` in the worker = crash. Join (`wait_to_finish`) in `_exit_tree`.
- **`call_deferred` argues by Variant** - passing a huge PackedByteArray copies it; wrap big payloads in a RefCounted holder.
- **Signals across threads:** `emit_signal` from a worker executes connections ON that worker thread. Connect with `CONNECT_DEFERRED` (or call_deferred the emit) so handlers run on main.
- **Blocking the main thread to "wait" for a worker defeats the point** - poll a flag in `_process` or use a deferred callback; never spin-wait.

Confirm class, property, and method names with `describe_class` (e.g. `class=ResourceLoader`, `class=WorkerThreadPool`, `class=Thread`) and `get_godot_version` before relying on them.
