@tool
extends RefCounted
class_name BeckettAssetLibTools

## Godot asset access — search / info / install — over a hand-rolled SYNCHRONOUS
## HTTPClient (the dispatcher calls tool handlers synchronously, so no await is
## possible), then extracts the downloaded zip with ZIPReader the way the editor's
## installer does: strip the single wrapper directory and write everything under res://.
##
## TWO BACKENDS, version-gated (Godot 4.7 replaced the Asset Library with the Asset
## Store; the old REST API is deprecated/read-only but still answers, so we keep it
## for ≤4.6):
##   • 4.7+  → the new Asset Store at store.godotengine.org/api/v1 (slug-keyed assets,
##             a separate /releases/ call for the download URL).
##   • ≤4.6  → the legacy Asset Library at godotengine.org/asset-library/api (int ids).
## Both backends are normalized to one output schema, and assets are identified by a
## single opaque 'ref' (a "publisher/asset" slug on 4.7+, the numeric id on ≤4.6) that
## asset_lib_search hands to asset_lib_info / asset_lib_install.
##
## Override the bases with BECKETT_ASSET_STORE_URL / BECKETT_ASSET_LIB_URL, or force a
## backend with BECKETT_ASSET_BACKEND=new|old (the store is in beta — this is the hedge).
##
## Install blocks the editor while it downloads — acceptable for an explicit action.

const _LIB_API := "https://godotengine.org/asset-library/api"
const _STORE_API := "https://store.godotengine.org/api/v1"
const _UA := "beckett-godot-mcp/0.1 (+https://godotengine.org)"
const _MAX_DOWNLOAD := 128 * 1024 * 1024
const _TMP_ZIP := "user://mcp_asset_dl.zip"

var server


func _register(registry) -> void:
	registry.register({
		"name": "asset_lib_search",
		"description": "Search the Godot Asset Store (4.7+; auto-falls back to the legacy Asset Library API on ≤4.6). 'query' filters by text (omit to browse the latest); optional 'type' (addon|project, default addon), 'sort' (updated|created|reviews|relevance — relevance needs a query), 'godot_version' (compatibility filter, default engine x.y), 'max_results' (default 20), 'page' (1-based on the store). Each hit carries a 'ref' — pass it to asset_lib_info / asset_lib_install.",
		"readonly": true,
		"open_world": true,
		"input_schema": {"type": "object", "properties": {
			"query": {"type": "string"},
			"type": {"type": "string"},
			"category": {"type": "string", "description": "legacy (≤4.6) only"},
			"support": {"type": "string", "description": "legacy (≤4.6) only"},
			"sort": {"type": "string"},
			"godot_version": {"type": "string"},
			"max_results": {"type": "integer"},
			"page": {"type": "integer"},
		}},
		"handler": Callable(self, "_search"),
	})
	registry.register({
		"name": "asset_lib_info",
		"description": "Fetch full details for one asset. Pass 'ref' from asset_lib_search (a \"publisher/asset\" slug on 4.7+, or the numeric id on ≤4.6). Returns title/author/cost/version_string/godot_version/download_url/browse_url/description (+ license/tags/reviews_score on the 4.7 store). 'asset_id' (int) is still accepted on ≤4.6.",
		"readonly": true,
		"open_world": true,
		"input_schema": {"type": "object", "properties": {
			"ref": {"type": "string", "description": "asset ref from asset_lib_search (\"publisher/asset\" or numeric id)"},
			"asset_id": {"type": "integer", "description": "legacy (≤4.6) numeric id"},
		}},
		"handler": Callable(self, "_info"),
	})
	registry.register({
		"name": "asset_lib_install",
		"description": "Download an asset and extract it into res:// (mirrors the editor installer: strips the wrapper dir, writes under res://). Provide 'ref' (from asset_lib_search) or a direct 'url' to a .zip. On 4.7+ this resolves the newest stable release's download; on ≤4.6 it uses the legacy API. 'enable':true enables any installed addon plugin afterward. Blocks until done, then rescans the filesystem. Destructive — writes many files.",
		"destructive": true,
		"open_world": true,
		"input_schema": {"type": "object", "properties": {
			"ref": {"type": "string", "description": "asset ref from asset_lib_search"},
			"asset_id": {"type": "integer", "description": "legacy (≤4.6) numeric id"},
			"url": {"type": "string", "description": "direct .zip URL; overrides ref's download_url"},
			"enable": {"type": "boolean"},
		}},
		"handler": Callable(self, "_install"),
	})



func _search(args: Dictionary) -> Dictionary:
	return _search_new(args) if _use_new_store() else _search_old(args)


func _info(args: Dictionary) -> Dictionary:
	return _info_new(args) if _use_new_store() else _info_old(args)


func _install(args: Dictionary) -> Dictionary:
	var direct := str(args.get("url", ""))
	if direct != "":
		return _do_install(direct, "asset", bool(args.get("enable", false)))
	return _install_new(args) if _use_new_store() else _install_old(args)



func _search_new(args: Dictionary) -> Dictionary:
	var q := str(args.get("query", "")).strip_edges()
	if q != "":
		return _store_query(args, q)
	return _store_browse(args)


## Text search: GET /search/query/ -> {count, hits:[{asset, highlights}]}.
func _store_query(args: Dictionary, q: String) -> Dictionary:
	var page := maxi(1, int(args.get("page", 1)))
	var url := _store_base() + "/search/query/?" + "&".join([
		"query=" + q.uri_encode(),
		"type=" + str(_type_int(str(args.get("type", "addon")))),
		"compatibility=" + str(args.get("godot_version", _engine_ver())).uri_encode(),
		"sort=" + _sort_new(str(args.get("sort", "relevance"))),
		"page=" + str(page),
		"batch_size=" + str(int(args.get("max_results", 20))),
	])
	var r := _get_json(url)
	if r.has("error"):
		return r
	var d: Variant = r["data"]
	if typeof(d) != TYPE_DICTIONARY:
		return {"error": "unexpected search response"}
	var out: Array = []
	for hit in d.get("hits", []):
		if typeof(hit) == TYPE_DICTIONARY and typeof(hit.get("asset")) == TYPE_DICTIONARY:
			out.append(_norm_asset_new(hit["asset"]))
	return {"json": {
		"backend": "store",
		"page": page,
		"total_items": str(d.get("count", "0")).to_int(),
		"count": out.size(),
		"results": out,
	}}


## Browse latest (no text): GET /assets/ -> bare array + X-Pagination header.
func _store_browse(args: Dictionary) -> Dictionary:
	var page := maxi(1, int(args.get("page", 1)))
	var url := _store_base() + "/assets/?" + "&".join([
		"type=" + str(_type_int(str(args.get("type", "addon")))),
		"compatibility=" + str(args.get("godot_version", _engine_ver())).uri_encode(),
		"page=" + str(page),
		"page_size=" + str(int(args.get("max_results", 20))),
	])
	var r := _http_get(url)
	if not bool(r.get("ok", false)):
		return {"error": "HTTP error from %s: %s" % [url, str(r.get("error", "unknown"))]}
	var body: PackedByteArray = r.get("body", PackedByteArray())
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_ARRAY:
		return {"error": "unexpected browse response"}
	var out: Array = []
	for a in parsed:
		if typeof(a) == TYPE_DICTIONARY:
			out.append(_norm_asset_new(a))
	var pg := _pagination(r.get("headers", {}))
	return {"json": {
		"backend": "store",
		"page": int(pg.get("page", page)),
		"pages": int(pg.get("total_pages", 0)),
		"total_items": int(pg.get("total", out.size())),
		"count": out.size(),
		"results": out,
	}}


func _info_new(args: Dictionary) -> Dictionary:
	var p := _parse_ref(_ref_arg(args))
	if p.get("kind", "") != "slug":
		return {"error": "the 4.7 Asset Store identifies assets by slug — pass 'ref' as \"publisher/asset\" from asset_lib_search"}
	var pub: String = p["publisher"]
	var slug: String = p["asset"]
	var base := _store_base()
	var d := _get_json("%s/assets/%s/%s/" % [base, pub.uri_encode(), slug.uri_encode()])
	if d.has("error"):
		return d
	var a: Variant = d["data"]
	if typeof(a) != TYPE_DICTIONARY:
		return {"error": "unexpected asset response"}
	var norm := _norm_asset_new(a)
	norm["backend"] = "store"
	norm["browse_url"] = _s(a.get("store_url"))
	norm["source_url"] = _s(a.get("source"))
	norm["description"] = _truncate(_s(a.get("description")), 2000)
	var rel := _store_release(base, pub, slug)
	if not rel.is_empty():
		norm["version_string"] = _s(rel.get("version"))
		norm["godot_version"] = _ver_range(rel)
		norm["download_url"] = _s(rel.get("download_url"))
		norm["size_mb"] = rel.get("size", 0)
	return {"json": norm}


func _install_new(args: Dictionary) -> Dictionary:
	var p := _parse_ref(_ref_arg(args))
	if p.get("kind", "") != "slug":
		return {"error": "the 4.7 Asset Store needs 'ref' as \"publisher/asset\" (from asset_lib_search) or a direct 'url'"}
	var pub: String = p["publisher"]
	var slug: String = p["asset"]
	var rel := _store_release(_store_base(), pub, slug)
	if rel.is_empty():
		return {"error": "no downloadable release for %s" % _ref_arg(args)}
	var url := _s(rel.get("download_url"))
	if url == "":
		return {"error": "release for %s has no download_url" % _ref_arg(args)}
	return _do_install(url, slug, bool(args.get("enable", false)))


## Pick the newest stable release (the API returns them newest-first), else the newest.
func _store_release(base: String, pub: String, slug: String) -> Dictionary:
	var r := _get_json("%s/releases/%s/%s/" % [base, pub.uri_encode(), slug.uri_encode()])
	if r.has("error"):
		return {}
	var arr: Variant = r["data"]
	if typeof(arr) != TYPE_ARRAY or (arr as Array).is_empty():
		return {}
	for it in arr:
		if typeof(it) == TYPE_DICTIONARY and bool(it.get("stable", false)):
			return it
	var first: Variant = arr[0]
	return first if typeof(first) == TYPE_DICTIONARY else {}


## Map an Asset Store asset object to the common output schema.
func _norm_asset_new(a: Dictionary) -> Dictionary:
	var pub_slug := ""
	var author := ""
	var pub: Variant = a.get("publisher")
	if typeof(pub) == TYPE_DICTIONARY:
		pub_slug = _s(pub.get("slug"))
		author = _s(pub.get("name"))
	var slug := _s(a.get("slug"))
	var ref := pub_slug + "/" + slug if pub_slug != "" and slug != "" else slug
	var tags: Array = []
	for t in a.get("tags", []):
		if typeof(t) == TYPE_DICTIONARY:
			tags.append(_s(t.get("display_name", t.get("slug"))))
	var price := int(a.get("price_cent", 0))
	return {
		"ref": ref,
		"title": _s(a.get("name")),
		"author": author,
		"category": ", ".join(tags),
		"tags": tags,
		"cost": ("" if price == 0 else "%.2f" % (price / 100.0)),
		"price_cent": price,
		"license": _s(a.get("license_type")),
		"support_level": "",
		"reviews_score": a.get("reviews_score", 0),
		"version_string": "",
		"godot_version": "",
		"store_url": _s(a.get("store_url")),
	}



func _search_old(args: Dictionary) -> Dictionary:
	var qparts: Array = [
		"type=" + str(args.get("type", "addon")),
		"godot_version=" + str(args.get("godot_version", _engine_ver())),
		"max_results=" + str(int(args.get("max_results", 20))),
		"page=" + str(int(args.get("page", 0))),
		"sort=" + str(args.get("sort", "updated")),
		"support=" + str(args.get("support", "official+community+testing")),
	]
	var q := str(args.get("query", ""))
	if q != "":
		qparts.append("filter=" + q.uri_encode())
	var cat := str(args.get("category", ""))
	if cat != "":
		qparts.append("category=" + cat.uri_encode())
	var r := _get_json(_lib_base() + "/asset?" + "&".join(qparts))
	if r.has("error"):
		return r
	var data: Variant = r["data"]
	if typeof(data) != TYPE_DICTIONARY:
		return {"error": "unexpected search response"}
	var out: Array = []
	for a in data.get("result", []):
		out.append({
			"ref": str(a.get("asset_id", "")),
			"asset_id": a.get("asset_id", ""),
			"title": a.get("title", ""),
			"author": a.get("author", ""),
			"category": a.get("category", ""),
			"cost": a.get("cost", ""),
			"support_level": a.get("support_level", ""),
			"version_string": a.get("version_string", ""),
			"godot_version": a.get("godot_version", ""),
		})
	return {"json": {
		"backend": "library",
		"page": data.get("page", 0),
		"pages": data.get("pages", 0),
		"total_items": data.get("total_items", 0),
		"count": out.size(),
		"results": out,
	}}


func _info_old(args: Dictionary) -> Dictionary:
	var id := _legacy_id(args)
	if id <= 0:
		return {"error": "asset_id (or a numeric ref) is required"}
	var r := _get_json("%s/asset/%d" % [_lib_base(), id])
	if r.has("error"):
		return r
	var a: Variant = r["data"]
	if typeof(a) != TYPE_DICTIONARY:
		return {"error": "unexpected asset response"}
	return {"json": {
		"backend": "library",
		"ref": str(a.get("asset_id", id)),
		"asset_id": a.get("asset_id", id),
		"title": a.get("title", ""),
		"author": a.get("author", ""),
		"category": a.get("category", ""),
		"cost": a.get("cost", ""),
		"support_level": a.get("support_level", ""),
		"version_string": a.get("version_string", ""),
		"godot_version": a.get("godot_version", ""),
		"download_url": a.get("download_url", ""),
		"download_commit": a.get("download_commit", ""),
		"browse_url": a.get("browse_url", ""),
		"issues_url": a.get("issues_url", ""),
		"description": _truncate(str(a.get("description", "")), 2000),
	}}


func _install_old(args: Dictionary) -> Dictionary:
	var id := _legacy_id(args)
	if id <= 0:
		return {"error": "provide 'ref' (or 'asset_id') or a direct 'url'"}
	var info := _get_json("%s/asset/%d" % [_lib_base(), id])
	if info.has("error"):
		return info
	var a: Variant = info["data"]
	if typeof(a) != TYPE_DICTIONARY:
		return {"error": "unexpected asset response"}
	var url := str(a.get("download_url", ""))
	if url == "":
		return {"error": "asset %d has no download_url" % id}
	return _do_install(url, str(a.get("title", "asset")), bool(args.get("enable", false)))



static func _use_new_store() -> bool:
	match OS.get_environment("BECKETT_ASSET_BACKEND").to_lower():
		"new", "store":
			return true
		"old", "library":
			return false
	var v := Engine.get_version_info()
	var major := int(v.get("major", 4))
	var minor := int(v.get("minor", 0))
	return major > 4 or (major == 4 and minor >= 7)


static func _store_base() -> String:
	var e := OS.get_environment("BECKETT_ASSET_STORE_URL")
	return e if e != "" else _STORE_API


static func _lib_base() -> String:
	var e := OS.get_environment("BECKETT_ASSET_LIB_URL")
	return e if e != "" else _LIB_API


## The effective ref string (prefers 'ref', falls back to the legacy 'asset_id' int).
static func _ref_arg(args: Dictionary) -> String:
	var ref := str(args.get("ref", "")).strip_edges()
	if ref != "":
		return ref
	var id := int(args.get("asset_id", 0))
	return str(id) if id > 0 else ""


## {kind:"slug", publisher, asset} for "publisher/asset", {kind:"id", id} for "123", else {}.
static func _parse_ref(ref: String) -> Dictionary:
	if ref == "":
		return {}
	if ref.contains("/"):
		var parts := ref.split("/", false)
		if parts.size() < 2:
			return {}
		return {"kind": "slug", "publisher": parts[0], "asset": parts[1]}
	if ref.is_valid_int():
		return {"kind": "id", "id": ref.to_int()}
	return {}


## Resolve a legacy integer id from either 'asset_id' or a numeric 'ref'.
static func _legacy_id(args: Dictionary) -> int:
	var id := int(args.get("asset_id", 0))
	if id > 0:
		return id
	var p := _parse_ref(_ref_arg(args))
	return int(p["id"]) if p.get("kind", "") == "id" else 0


static func _type_int(t: String) -> int:
	return 1 if t.to_lower() == "project" else 0


static func _sort_new(s: String) -> String:
	match s.to_lower():
		"updated", "updated_desc":
			return "updated_desc"
		"updated_asc":
			return "updated_asc"
		"created", "new", "created_desc":
			return "created_desc"
		"created_asc":
			return "created_asc"
		"reviews", "rating", "reviews_desc":
			return "reviews_desc"
		"reviews_asc":
			return "reviews_asc"
		_:
			return "relevance"


static func _ver_range(rel: Dictionary) -> String:
	var mn := _s(rel.get("min_godot_version"))
	var mx := _s(rel.get("max_godot_version"))
	if mn != "" and mx != "" and mx != mn:
		return mn + " - " + mx
	return mn


func _pagination(headers: Dictionary) -> Dictionary:
	var raw := _header(headers, "x-pagination")
	if raw == "":
		return {}
	var p: Variant = JSON.parse_string(raw)
	return p if typeof(p) == TYPE_DICTIONARY else {}



func _do_install(url: String, title: String, enable: bool) -> Dictionary:
	var dl := _http_get(url)
	if not bool(dl.get("ok", false)):
		return {"error": "download failed: %s" % str(dl.get("error", "unknown"))}
	var bytes: PackedByteArray = dl.get("body", PackedByteArray())
	if bytes.is_empty():
		return {"error": "downloaded 0 bytes from %s" % url}
	return _extract_zip(bytes, title, enable, url)


func _extract_zip(bytes: PackedByteArray, title: String, enable: bool, src: String) -> Dictionary:
	var f := FileAccess.open(_TMP_ZIP, FileAccess.WRITE)
	if f == null:
		return {"error": "cannot write temp zip: %s" % error_string(FileAccess.get_open_error())}
	f.store_buffer(bytes)
	f.close()
	var zip := ZIPReader.new()
	var err := zip.open(_TMP_ZIP)
	if err != OK:
		DirAccess.remove_absolute(_TMP_ZIP)
		return {"error": "not a readable zip (%s) from %s" % [error_string(err), src]}
	var entries := zip.get_files()
	var root := _common_root(entries)
	var written: Array = []
	var skipped: Array = []
	var plugins: Array = []
	for entry in entries:
		if entry.ends_with("/"):
			continue
		var rel := entry
		if root != "" and rel.begins_with(root):
			rel = rel.substr(root.length())
		if rel == "" or rel.contains(".."):
			skipped.append(entry)
			continue
		var dest := "res://" + rel
		var dir := dest.get_base_dir()
		if dir != "" and not DirAccess.dir_exists_absolute(dir):
			DirAccess.make_dir_recursive_absolute(dir)
		var out := FileAccess.open(dest, FileAccess.WRITE)
		if out == null:
			skipped.append(entry)
			continue
		out.store_buffer(zip.read_file(entry, true))
		out.close()
		written.append(dest)
		if dest.begins_with("res://addons/") and dest.ends_with("/plugin.cfg"):
			plugins.append(_plugin_name(dest))
	zip.close()
	DirAccess.remove_absolute(_TMP_ZIP)
	if written.is_empty():
		return {"error": "zip held no installable files (%d skipped)" % skipped.size()}
	var preserved := _preserve_beckett(written)
	var enabled: Array = []
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
		if enable:
			for p in plugins:
				EditorInterface.set_plugin_enabled(p, true)
				enabled.append(p)
	return {"json": {
		"title": title,
		"source": src,
		"installed_files": written.size(),
		"skipped": skipped.size(),
		"plugins_found": plugins,
		"plugins_enabled": enabled,
		"beckett_preserved": preserved,
		"files_preview": written.slice(0, 40),
		"note": ("Filesystem rescanned; requested plugins enabled." if enable
			else "Filesystem rescanned. Enable any addon under Project > Project Settings > Plugins."),
	}}


## Re-inject beckett's autoload(s) + plugin into project.godot after a project-type asset
## overwrote it. The editor's in-memory ProjectSettings still holds the bootstrap, so we
## merge beckett's entries into the kit's new file, leaving the kit's own settings intact.
## Returns a short report of what was restored (empty when project.godot wasn't touched).
func _preserve_beckett(written: Array) -> Dictionary:
	var report := {}
	if not Engine.is_editor_hint() or not written.has("res://project.godot"):
		return report
	var cf := ConfigFile.new()
	if cf.load("res://project.godot") != OK:
		return report
	var restored_autoloads := PackedStringArray()
	for prop in ProjectSettings.get_property_list():
		var n := str(prop.get("name", ""))
		if not n.begins_with("autoload/"):
			continue
		var v: Variant = ProjectSettings.get_setting(n)
		if not (n.to_lower().contains("beckett") or str(v).to_lower().contains("beckett")):
			continue
		var key := n.substr("autoload/".length())
		if cf.get_value("autoload", key, null) == null:
			cf.set_value("autoload", key, v)
			restored_autoloads.append(key)
	var merged := PackedStringArray()
	for e in cf.get_value("editor_plugins", "enabled", PackedStringArray()):
		merged.append(str(e))
	var restored_plugins := PackedStringArray()
	for p in ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray()):
		if str(p).to_lower().contains("beckett") and not merged.has(str(p)):
			merged.append(str(p))
			restored_plugins.append(str(p))
	if merged.size() > 0:
		cf.set_value("editor_plugins", "enabled", merged)
	if restored_autoloads.size() > 0 or restored_plugins.size() > 0:
		cf.save("res://project.godot")
		report["autoloads"] = restored_autoloads
		report["plugins"] = restored_plugins
	return report



## Synchronous GET that follows redirects. Returns {ok, code, body:PackedByteArray, headers}
## or {ok:false, error}.
func _http_get(url: String, max_redirects := 6) -> Dictionary:
	var current := url
	for _i in range(max_redirects + 1):
		var u := _parse_url(current)
		if u.is_empty():
			return {"ok": false, "error": "bad URL: %s" % current}
		var client := HTTPClient.new()
		var tls: TLSOptions = TLSOptions.client() if u["tls"] else null
		var err := client.connect_to_host(u["host"], u["port"], tls)
		if err != OK:
			return {"ok": false, "error": "connect_to_host failed: %s" % error_string(err)}
		var deadline := Time.get_ticks_msec() + 30000
		while true:
			var st := client.get_status()
			if st == HTTPClient.STATUS_CONNECTED:
				break
			if st != HTTPClient.STATUS_CONNECTING and st != HTTPClient.STATUS_RESOLVING:
				return {"ok": false, "error": "connection failed (status %d) to %s" % [st, u["host"]]}
			client.poll()
			if Time.get_ticks_msec() > deadline:
				return {"ok": false, "error": "connect timeout to %s" % u["host"]}
			OS.delay_msec(5)
		var headers := PackedStringArray(["User-Agent: " + _UA, "Accept: application/json, */*"])
		err = client.request(HTTPClient.METHOD_GET, u["path"], headers)
		if err != OK:
			return {"ok": false, "error": "request failed: %s" % error_string(err)}
		deadline = Time.get_ticks_msec() + 30000
		while client.get_status() == HTTPClient.STATUS_REQUESTING:
			client.poll()
			if Time.get_ticks_msec() > deadline:
				return {"ok": false, "error": "request timeout to %s" % u["host"]}
			OS.delay_msec(5)
		var code := client.get_response_code()
		var hdrs := client.get_response_headers_as_dictionary()
		if code in [301, 302, 303, 307, 308]:
			var loc := _header(hdrs, "location")
			client.close()
			if loc == "":
				return {"ok": false, "error": "redirect %d without Location" % code}
			current = _resolve(current, loc)
			continue
		var body := PackedByteArray()
		deadline = Time.get_ticks_msec() + 120000
		while client.get_status() == HTTPClient.STATUS_BODY:
			client.poll()
			var chunk := client.read_response_body_chunk()
			if chunk.size() > 0:
				body.append_array(chunk)
				if body.size() > _MAX_DOWNLOAD:
					client.close()
					return {"ok": false, "error": "response exceeds %d bytes" % _MAX_DOWNLOAD}
			elif Time.get_ticks_msec() > deadline:
				return {"ok": false, "error": "body read timeout from %s" % u["host"]}
			else:
				OS.delay_msec(2)
		client.close()
		if code < 200 or code >= 300:
			return {"ok": false, "error": "HTTP %d" % code, "code": code}
		return {"ok": true, "code": code, "body": body, "headers": hdrs}
	return {"ok": false, "error": "too many redirects"}


func _get_json(url: String) -> Dictionary:
	var r := _http_get(url)
	if not bool(r.get("ok", false)):
		return {"error": "HTTP error from %s: %s" % [url, str(r.get("error", "unknown"))]}
	var body: PackedByteArray = r.get("body", PackedByteArray())
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null:
		return {"error": "invalid JSON from %s" % url}
	return {"data": parsed}



static func _parse_url(url: String) -> Dictionary:
	var tls := false
	var rest := ""
	if url.begins_with("https://"):
		tls = true
		rest = url.substr(8)
	elif url.begins_with("http://"):
		rest = url.substr(7)
	else:
		return {}
	var slash := rest.find("/")
	var hostport := rest if slash == -1 else rest.substr(0, slash)
	var path := "/" if slash == -1 else rest.substr(slash)
	var host := hostport
	var port := 443 if tls else 80
	var colon := hostport.find(":")
	if colon != -1:
		host = hostport.substr(0, colon)
		port = hostport.substr(colon + 1).to_int()
	if path == "":
		path = "/"
	return {"tls": tls, "host": host, "port": port, "path": path}


static func _resolve(base: String, loc: String) -> String:
	if loc.begins_with("http://") or loc.begins_with("https://"):
		return loc
	var b := _parse_url(base)
	if b.is_empty():
		return loc
	var scheme := "https" if b["tls"] else "http"
	var authority := str(b["host"])
	if (b["tls"] and int(b["port"]) != 443) or (not b["tls"] and int(b["port"]) != 80):
		authority += ":" + str(b["port"])
	if loc.begins_with("/"):
		return "%s://%s%s" % [scheme, authority, loc]
	return "%s://%s%s/%s" % [scheme, authority, str(b["path"]).get_base_dir(), loc]


static func _header(h: Dictionary, key: String) -> String:
	var lk := key.to_lower()
	for k in h:
		if str(k).to_lower() == lk:
			return str(h[k])
	return ""


## GitHub-style zips wrap everything in one "<repo>-<hash>/" dir; return it (with trailing
## slash) so the caller can strip it. Empty string when entries don't share one root, or
## when that root is "addons/" itself (a real install location, never a wrapper to strip).
static func _common_root(files: PackedStringArray) -> String:
	var root := ""
	for entry in files:
		var slash := entry.find("/")
		if slash == -1:
			return ""
		var first := entry.substr(0, slash + 1)
		if root == "":
			root = first
		elif first != root:
			return ""
	return "" if root.to_lower() == "addons/" else root


static func _plugin_name(cfg_path: String) -> String:
	var rest := cfg_path.trim_prefix("res://addons/")
	var slash := rest.find("/")
	return rest.substr(0, slash) if slash != -1 else rest


static func _engine_ver() -> String:
	var v := Engine.get_version_info()
	return "%d.%d" % [int(v.get("major", 4)), int(v.get("minor", 0))]


static func _s(v) -> String:
	return "" if v == null else str(v)


static func _truncate(s: String, n: int) -> String:
	return s if s.length() <= n else s.substr(0, n) + "…"
