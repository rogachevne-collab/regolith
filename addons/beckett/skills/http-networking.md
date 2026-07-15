# HTTP networking - HTTPRequest, JSON, TLS (plain web calls, not peer multiplayer)

> For talking to web APIs, leaderboards, and downloads. This is DISTINCT from the `multiplayer` pack (peer-to-peer ENet/RPC). Use `HTTPRequest` (a Node, async, easy) for one-shot calls; drop to `HTTPClient` only for streaming/low-level control.

## Version note
- Server runs **4.6.2**; Beckett supports the **4.2+** floor. `HTTPRequest`, `HTTPClient`, `JSON`, `TLSOptions`, and the `Result`/`HTTPClient.Method` enums below are all **4.0+**, stable through 4.7.
- `HTTPRequest.set_tls_options(TLSOptions)` and the `TLSOptions.client()` / `client_unsafe()` factories exist since 4.0. `JSON.stringify` / `JSON.parse_string` are the 4.0 replacements for the removed 3.x `to_json` / `parse_json`. Confirm with `get_godot_version` / `describe_class class=HTTPRequest`.

## HTTPRequest - lifecycle (a Node in the tree)
1. `create_node type=HTTPRequest` and add it to the tree (it needs `_process` to poll; a bare `.new()` not in the tree never completes).
2. Connect its `request_completed` signal, then call `request(...)`.
3. `request(url: String, custom_headers := PackedStringArray(), method := HTTPClient.METHOD_GET, request_data := "") -> Error` - returns `OK` (0) if the request STARTED (bad url / busy returns an error immediately; a non-OK return means it never fired). Use `request_raw(..., request_data_raw: PackedByteArray)` to send binary.
- Signal: `request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray)`. `result` is a `Result` enum (transport outcome); `response_code` is the HTTP status (200/404/500). They are DIFFERENT axes - see traps.
- **One request per node at a time.** A second `request()` before the first completes returns `ERR_BUSY` (44). Use one node per concurrent call, or `await` the first.

### Properties
- `timeout: float = 0.0` (**0 = no timeout** - set a real value like `10.0` so a dead server does not hang forever), `use_threads: bool = false` (run the transfer off the main thread; keep the UI responsive on big downloads), `accept_gzip: bool = true` (auto-decompress), `max_redirects: int = 8`, `body_size_limit: int = -1` (-1 = unlimited; cap it to refuse huge bodies), `download_file: String = ""` (stream the body straight to a file path instead of memory), `download_chunk_size: int = 65536`.

## await pattern (cleanest for one-shot calls)
```gdscript
var http := HTTPRequest.new()
add_child(http)
http.request("https://api.example.com/scores")
var res: Array = await http.request_completed   # [result, response_code, headers, body]
var result: int = res[0]
var code: int = res[1]
var body: PackedByteArray = res[3]
if result == HTTPRequest.RESULT_SUCCESS and code == 200:
    var text := body.get_string_from_utf8()
    var data = JSON.parse_string(text)          # null on parse failure - check it
```

## Body <-> JSON
- Response body is a `PackedByteArray`: `body.get_string_from_utf8() -> String`, then `JSON.parse_string(text) -> Variant` (returns `null` on invalid JSON; for error detail use a `JSON.new()` instance + `parse(text)` + `get_error_message()` / `get_error_line()`).
- Outgoing payload: `JSON.stringify(dict) -> String`, pass as `request_data` with a `["Content-Type: application/json"]` header and `method = HTTPClient.METHOD_POST`.
- **HTTPClient.Method** for the `method` arg: `METHOD_GET=0`, `METHOD_POST=3`, `METHOD_PUT=4` (values vary by version - pass the SYMBOL `HTTPClient.METHOD_POST`, not an int).

## Result enum (transport-level, not HTTP status)
`RESULT_SUCCESS=0`, `RESULT_CHUNKED_BODY_SIZE_MISMATCH=1`, `RESULT_CANT_CONNECT=2`, `RESULT_CANT_RESOLVE=3` (DNS), `RESULT_CONNECTION_ERROR=4`, `RESULT_TLS_HANDSHAKE_ERROR=5`, `RESULT_NO_RESPONSE=6`, `RESULT_BODY_SIZE_LIMIT_EXCEEDED=7`, `RESULT_BODY_DECOMPRESS_FAILED=8`, `RESULT_REQUEST_FAILED=9`, `RESULT_DOWNLOAD_FILE_CANT_OPEN=10`, `RESULT_DOWNLOAD_FILE_WRITE_ERROR=11`, `RESULT_REDIRECT_LIMIT_REACHED=12`, `RESULT_TIMEOUT=13`. `RESULT_SUCCESS` only means "the exchange completed" - a 404/500 is still `RESULT_SUCCESS` with a non-200 `response_code`. Always check both.

## TLS (HTTPS)
- `HTTPRequest.set_tls_options(TLSOptions)` - usually unnecessary: `https://` uses the platform's trusted CA store by default. NO `certifi`/CA bundle wiring is needed in Godot 4 (unlike many engines); system CAs are used automatically.
- `TLSOptions.client(trusted_chain := null, common_name_override := "")` - pin a custom CA or override the expected hostname. `TLSOptions.client_unsafe(trusted_chain := null)` - DISABLES certificate verification; DEV ONLY (self-signed local servers), never ship it (opens you to MITM).

## HTTPClient - low-level / streaming (prefer HTTPRequest unless you need this)
- Manual state machine: `connect_to_host(host, port := -1, tls_options := null) -> Error`, then `poll()` in a loop until `get_status()` reaches `STATUS_CONNECTED`, `request(method, url, headers, body := "") -> Error`, poll to `STATUS_BODY`, pull chunks with `read_response_body_chunk() -> PackedByteArray`.
- Reach for `HTTPClient` when you must: stream a large download in chunks without buffering the whole body, send many requests over one kept-alive connection, or read the response incrementally. It does NOT auto-poll - you drive `poll()` yourself. For 95% of game needs, `HTTPRequest` is correct.

## Recipe - GET a leaderboard as JSON (Beckett-driven)
```
create_node type=HTTPRequest name=Http parent=.
write_script path=res://api.gd content="extends HTTPRequest
signal loaded(scores)
func fetch() -> void:
    timeout = 10.0                                   # never 0 in shipped code
    request_completed.connect(_done)
    var err := request(\"https://api.example.com/scores\")
    if err != OK:
        push_error(\"request failed to start: %d\" % err)
func _done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
    if result != RESULT_SUCCESS or code != 200:
        push_error(\"http %d / result %d\" % [code, result]); return
    var data = JSON.parse_string(body.get_string_from_utf8())
    if data == null:
        push_error(\"bad json\"); return
    loaded.emit(data)"
attach_script target=Http path=res://api.gd
play_scene → call_method target=Http method=fetch args=[] → wait_until condition="not Http.get_meta(\"busy\", false)" timeout_ms=12000 → game_logs → stop_scene
```

## Recipe - POST JSON with a header
```
write_script path=res://post.gd content="extends HTTPRequest
func send(payload: Dictionary) -> void:
    request_completed.connect(func(r, c, _h, b):
        print(\"result \", r, \" code \", c, \" body \", b.get_string_from_utf8()))
    var headers := PackedStringArray([\"Content-Type: application/json\"])
    var body := JSON.stringify(payload)
    var err := request(\"https://api.example.com/submit\", headers, HTTPClient.METHOD_POST, body)
    if err != OK: push_error(\"start failed %d\" % err)"
attach_script target=Http path=res://post.gd
play_scene → call_method target=Http method=send args=[{"score": 4200}] → game_logs → stop_scene
```

## Recipe - download a file to user://
```
set_property target=Http property=download_file value="user://patch.zip"   # stream to disk, not memory
call_method target=Http method=request args=["https://example.com/patch.zip"]
# body arrives on disk; res:// is READ-ONLY in exported builds - always download to user://
```

## Common traps
- **`result` vs `response_code` confusion** - `RESULT_SUCCESS` means the HTTP exchange completed; a 404/500 is STILL `RESULT_SUCCESS`. Check `result == RESULT_SUCCESS` AND `response_code == 200` (or your expected code). Reading only one hides real failures.
- **Node must be in the tree** - a bare `HTTPRequest.new()` never polls; `add_child(http)` (or `create_node`) first, or `request_completed` never fires.
- **One in-flight request per node** - a second `request()` before completion returns `ERR_BUSY (44)`. Pool nodes or `await` the previous one.
- **Blocking the main thread** - `HTTPRequest` is async and does NOT block by itself, but doing heavy `JSON.parse_string` on a multi-MB body in the completion handler stalls the frame; set `use_threads=true` for big transfers and parse off the main thread if huge.
- **`res://` is read-only in exports** - `download_file` and any runtime write must target `user://`. Writing to `res://` works in the editor and silently fails in an exported build (a top shippability bug).
- **`timeout=0` hangs forever** - the default never times out; set `timeout` to a real value in shipped code, and handle `RESULT_TIMEOUT` / `RESULT_CANT_RESOLVE` / `RESULT_CANT_CONNECT` for offline users.
- **`JSON.parse_string` returns `null` on bad JSON** - always null-check before indexing; use a `JSON.new()` instance for `get_error_message()`/`get_error_line()` when you need the reason.
- **No CA wiring needed** - do NOT try to bundle `certifi` or a CA file; Godot 4 uses system CAs. `client_unsafe()` is DEV ONLY and must never ship.
- **Android needs the INTERNET permission** - export → Android permissions → enable `INTERNET`, or every request fails on device (works in the editor, breaks on the phone). iOS allows outbound HTTPS by default; plain HTTP may be blocked by ATS.

Confirm exact class, property, and method names with `describe_class` (e.g. `class=HTTPRequest`, `class=JSON`, `class=TLSOptions`) and `get_godot_version` before relying on them.
