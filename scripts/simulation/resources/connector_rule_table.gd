class_name ConnectorRuleTable
extends Resource

## Which connector tags mate. Data, not code: a new part type adds a rule
## here and never edits matching/snapping/preview logic.

const DEFAULT_TABLE_PATH := "res://resources/connectors/connector_rules.tres"

@export var rules: Array[ConnectorRule] = []:
	set(value):
		rules = value
		_pair_lookup.clear()

static var _default: ConnectorRuleTable

var _pair_lookup: Dictionary = {}


static func default_table() -> ConnectorRuleTable:
	if _default == null:
		var loaded: Resource = null
		if ResourceLoader.exists(DEFAULT_TABLE_PATH):
			loaded = load(DEFAULT_TABLE_PATH)
		if loaded is ConnectorRuleTable:
			_default = loaded
		else:
			_default = _builtin()
	return _default


## Empty tag means plain structural surface.
static func normalize_tag(tag: String) -> String:
	if tag.is_empty():
		return "structural"
	return tag


func compatible(left_tag: String, right_tag: String) -> bool:
	if _pair_lookup.is_empty():
		_rebuild_lookup()
	return _pair_lookup.has(
		_pair_key(normalize_tag(left_tag), normalize_tag(right_tag))
	)


static func _builtin() -> ConnectorRuleTable:
	var table := ConnectorRuleTable.new()
	table.rules = [
		_rule("structural", "structural"),
		_rule("wheel_socket", "wheel_plug"),
	]
	return table


static func _rule(tag_a: String, tag_b: String) -> ConnectorRule:
	var rule := ConnectorRule.new()
	rule.tag_a = tag_a
	rule.tag_b = tag_b
	return rule


func _rebuild_lookup() -> void:
	_pair_lookup.clear()
	for rule: ConnectorRule in rules:
		if rule == null:
			continue
		var tag_a := normalize_tag(rule.tag_a)
		var tag_b := normalize_tag(rule.tag_b)
		_pair_lookup[_pair_key(tag_a, tag_b)] = true
		_pair_lookup[_pair_key(tag_b, tag_a)] = true


static func _pair_key(left_tag: String, right_tag: String) -> String:
	return left_tag + "|" + right_tag
