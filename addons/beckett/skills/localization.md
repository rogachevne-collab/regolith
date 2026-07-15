# Localization & translation — TranslationServer, tr/atr, auto_translate, CSV/gettext, pseudolocalization

> Localize via `TranslationServer` + `Translation` resources. `Control` text auto-translates by key; everything else you wrap in `tr()`/`atr()`. Set the active language with `TranslationServer.set_locale(locale)`.

## Version note
- Server runs **4.6.2** (baseline 4.3+). Check `get_godot_version`; confirm methods with `describe_class`.
- **`Node.auto_translate_mode`** (enum `AutoTranslateMode`) + **`atr()`/`atr_n()`**: added **4.3**. Replaced the per-`Control` bool `Control.auto_translate` (deprecated 4.3, removed in Godot 5; `auto_translate=false` == `AUTO_TRANSLATE_MODE_DISABLED`). New nodes default to INHERIT; only the **root** defaults to ALWAYS.
- **`Node.can_auto_translate()`**: added **4.5** (NOT in 4.3/4.4). Guard with a version check before calling it on older projects; present on 4.6.2.
- **`TranslationDomain`** class, **`Object.set_translation_domain`/`get_translation_domain`**, **`Node.set_translation_domain_inherited()`**, **`TranslationServer.get_or_add_domain`/`has_domain`/`remove_domain`/`find_translations`/`has_translation_for_locale`**: added **4.4**. `TranslationServer.get_translation_object(locale)` is **deprecated** in favor of `find_translations(locale, exact)`.
- CSV importer optional **`?context`** disambiguation column (== gettext `msgctxt`): added **4.6**.
- Pseudolocalization (`TranslationServer.pseudolocalization_enabled`): present since **4.0**; per-domain pseudolocalization props came with `TranslationDomain` in 4.4.

## Required setup
- **Register catalogs**: ProjectSetting `internationalization/locale/translations` (PackedStringArray of `res://` paths to `.translation`/`.po`/`.mo`). Files are **NOT auto-registered after import** — add them here (UI: Project > Project Settings > Localization > Translations).
- **Fallback**: `internationalization/locale/fallback` (String, default `"en"`).
- **Test in-editor**: `internationalization/locale/test` (String), or menu *View > Preview Translation*, or launch `godot --language fr`.
- **Root auto-translate**: `internationalization/rendering/root_node_auto_translate` (bool, default true → root = ALWAYS; false → DISABLED). **Read only at startup** — at runtime set `SceneTree.root.auto_translate_mode`.
- **Pseudoloc master switch**: `internationalization/pseudolocalization/use_pseudolocalization` (bool, default false). **Read only at startup** — at runtime use `TranslationServer.pseudolocalization_enabled` + `reload_pseudolocalization()`.
- **CSV authoring**: UTF-8 **without BOM**; header row first column **must be `keys`**, remaining headers are locale codes (`en`,`es`,`ja`). Top-left cell ignored. Importer produces one `.translation` per locale. Import dock options: Delimiter (Comma/Semicolon/Tab), Compress (bool).
- **gettext**: install GNU gettext CLI (`msgmerge`/`msgfmt`) and/or Poedit; generate the POT via *Project Settings > Localization > POT Generation*. Only nodes whose `auto_translate_mode` is not DISABLED are scanned.
- **No autoload needed** — `TranslationServer` is a built-in singleton. `tr`/`tr_n` need an Object instance; for static/utility code use `TranslationServer.translate()`/`translate_plural()`.

## TranslationServer (singleton, inherits Object)
- `void set_locale(locale: String)` / `String get_locale() const` — active locale; standardizes the string (`en-US` → `en_US`). Applies immediately if that locale is already loaded.
- `StringName translate(message, context := &"") const` / `translate_plural(message, plural_message, n, context := &"")` — static-context translation against the main domain (no Object needed).
- `void add_translation(t: Translation)` / `remove_translation(t)` / `clear()` / `Array[Translation] get_translations() const`.
- `Array[Translation] find_translations(locale, exact) const` (4.4), `bool has_translation_for_locale(locale, exact) const` (4.4), `PackedStringArray get_loaded_locales() const`.
- `String standardize_locale(locale, add_defaults := false) const`, `int compare_locales(a, b) const` (0 = no match, higher = closer), `String get_locale_name(locale) const`.
- `bool pseudolocalization_enabled` (set_/is_), `void reload_pseudolocalization()`, `StringName pseudolocalize(message) const`.
- `TranslationDomain get_or_add_domain(domain: StringName)` / `has_domain` / `remove_domain` (4.4). Main domain is the empty `StringName &""`; names starting `godot.` are reserved.

## Object / Node translation API
- `String Object.tr(message: StringName, context := &"") const` — **always** translates (subject only to `set_message_translation`/`can_translate_messages()`); ignores `auto_translate_mode`. Returns input unchanged if no match. Cannot be called statically.
- `String Object.tr_n(message, plural_message: StringName, n: int, context := &"") const` — pluralized; `n` selects the form per the locale's plural rules. Negative/float `n` may misbehave — handle manually.
- `String Node.atr(message: String, context := &"") const` / `atr_n(...)` — like `tr`/`tr_n` but **also honors `auto_translate_mode`**; on 4.5+ returns input unchanged when `can_auto_translate()` is false.
- `Node.auto_translate_mode: int` (enum) — `AUTO_TRANSLATE_MODE_INHERIT=0`, `AUTO_TRANSLATE_MODE_ALWAYS=1`, `AUTO_TRANSLATE_MODE_DISABLED=2`. DISABLED also skips POT scanning for this node + its INHERIT descendants.
- `Object.set_translation_domain(d: StringName)` / `Node.set_translation_domain_inherited()` (4.4) — route `tr`/`atr` through a named domain; the latter reverts to inheriting from parent.
- **Signal/notification**: `NOTIFICATION_TRANSLATION_CHANGED = 2010` fires on every node when locale or `auto_translate_mode` changes (and on enter-tree, so children may not be ready — guard with `is_node_ready()`). Built-in Controls refresh automatically; manually-set strings must be re-applied here.

## Control (UI overrides)
- `auto_translate: bool` — **DEPRECATED** since 4.3 (use `Node.auto_translate_mode`).
- `text_direction: int` (`TEXT_DIRECTION_AUTO=0`, `LTR=1`, `RTL=2`, `INHERITED=3`).
- `layout_direction: int` (`LAYOUT_DIRECTION_INHERITED=0`, `APPLICATION_LOCALE=1`, `LTR=2`, `RTL=3`, `SYSTEM_LOCALE=4`). `APPLICATION_LOCALE` added 4.3; `LAYOUT_DIRECTION_LOCALE` retained as a deprecated alias for value 1.
- `language: String`, `structured_text_bidi_override: int` — per-control overrides. RTL mirroring (anchors/alignment/child order) is automatic when the locale is RTL.

## Translation resources
- `Translation` (Resource): `locale: String = "en"`, `plural_rules_override: String`; `add_message(src, xlated, context := &"")`, `get_message(...)`, `add_plural_message(...)`, `get_message_count()`.
- `OptimizedTranslation` — the compressed `Translation` subclass the CSV importer produces (`.translation` files). `TranslationPO` backs imported gettext `.po`/`.mo`. You rarely build these by hand, but you can construct a `Translation` in code and `add_translation()` it for fully dynamic locales.

## Recipe — register CSV catalogs and switch language at runtime
```
# strings.csv (UTF-8 no BOM): header  keys,en,es,ja  then rows e.g. GREET,"Hello!","Hola!","..."
# Godot imports it -> strings.en.translation / strings.es.translation / strings.ja.translation
call_method target=ProjectSettings method=set_setting args=["internationalization/locale/translations", ["res://i18n/strings.en.translation","res://i18n/strings.es.translation","res://i18n/strings.ja.translation"]]
call_method target=ProjectSettings method=set_setting args=["internationalization/locale/fallback","en"]
call_method target=ProjectSettings method=save args=[]
create_node type=Label name=Title parent=UI
set_property target=UI/Title property=text value=GREET          # auto-resolves: Label inherits ALWAYS from root
call_method target=TranslationServer method=set_locale args=["es"]   # Controls update; NOTIFICATION_TRANSLATION_CHANGED fires
play_scene
monitor_properties path=UI/Title property=text         # confirm Spanish string rendered
```

## Recipe — opt a subtree out; translate a formatted string manually
```
set_property target=UI/PlayerNamePanel property=auto_translate_mode value=2   # DISABLED (player-entered names)
write_script path=res://score.gd content="extends Label
var score := 0
func _ready(): _refresh()
func _notification(what):
    if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready(): _refresh()
func _refresh(): text = tr(\"SCORE_FMT\").format({n = score})   # SCORE_FMT = 'Score: {n}'
"
attach_script target=UI/Score path=res://score.gd
# plural + context strings are NEVER auto-translated -> always manual:
#   text = tr_n("%d apple","%d apples", n) % n
#   text = tr("Close","Actions")        # context arg disables auto Control translation
```

## Recipe — pseudolocalize at runtime to stress-test layouts
```
get_godot_version                                              # confirm runtime
describe_class class=TranslationServer                         # confirm pseudolocalization_enabled
set_property target=TranslationServer property=pseudolocalization_enabled value=true
call_method target=ProjectSettings method=set_setting args=["internationalization/pseudolocalization/expansion_ratio", 0.3]
call_method target=TranslationServer method=reload_pseudolocalization args=[]
play_scene
screenshot                                                    # bracketed/accented/expanded text exposes overflow + missing glyphs
```

## Common traps
- `tr()` **always** translates; `atr()` also honors `auto_translate_mode`. Use `atr` for formatted/custom-drawn text on nodes you may opt out via DISABLED.
- Auto-translation applies **only to built-in `Control` text** (Label, RichTextLabel, Button, OptionButton items, `Window` title, AcceptDialog, TabBar...). Strings you build, and **any string needing a context** (`?context`/`msgctxt`), must be wrapped in `tr()`/`tr_n()` manually.
- New nodes default to INHERIT; only the **root** is ALWAYS. DISABLED is recursive for POT scanning. Known 4.3 quirk (#108744): a node explicitly set to INHERIT may still be emitted into the POT regardless of parent — verify the generated POT and set DISABLED explicitly on subtrees to exclude.
- `use_pseudolocalization` and `root_node_auto_translate` are read **only at startup** — change them at runtime via `TranslationServer.pseudolocalization_enabled`/`reload_pseudolocalization()` and `SceneTree.root.auto_translate_mode`.
- `set_locale` standardizes input (`en-US`→`en_US`); if that locale's catalog isn't loaded, nothing visibly changes. Common pattern: `TranslationServer.set_locale(OS.get_locale_language())`.
- On locale change, re-apply manually-set strings in `_notification(NOTIFICATION_TRANSLATION_CHANGED)`; it arrives with enter-tree, so guard with `is_node_ready()`.
- **Fonts**: the default project font is Latin-only. CJK/Cyrillic/Arabic need a `FontFile`/`SystemFont` with proper glyphs via the `fallbacks` chain (and a Theme default font). Pseudoloc accents surface missing glyphs.
- **Plurals**: feed `n` to `tr_n` (to pick the form) **and** to your `%`/`format` (to display): `tr_n("%d apple","%d apples",n) % n`. Prefer named args `tr("{name} took {item}").format({name=..,item=..})` so translators can reorder.
- **`translation_domain` / `TranslationDomain` are 4.4+** and `can_auto_translate()` is 4.5+ — guard with `get_godot_version`/`describe_class` before use.
- **2D vs 3D**: the API is identical (on Object/Node), but only `Control` auto-translates. `Label3D`/`TextMesh` have no text-swap — set `.text = tr("KEY")` yourself; localized textures go through the Localization > Remaps tab.

Always confirm exact class, property, and method names with `describe_class` (and `get_godot_version`) before relying on them — these APIs shifted across 4.3/4.4/4.5/4.6.
