class_name ActionBarState
extends RefCounted
## Бар клавиш ControlSeat-хоста (CONTROL-ACTIONS-V0): page → slot → payload.
## Пустой Dictionary = слот свободен. Хранится side-table в SimulationWorld,
## ключ — element_id хоста (не assembly_id — «Разные сиденья на одной сборке
## имеют разные бары»), по образцу WheelInstanceState/SuspensionInstanceState.

const PAGE_COUNT := 9
const SLOTS_PER_PAGE := 9

## pages[page][slot] = Dictionary. Плоский Array — сериализуется без обёрток.
var pages: Array = []


func _init() -> void:
	for _page_index in range(PAGE_COUNT):
		var slots: Array = []
		for _slot_index in range(SLOTS_PER_PAGE):
			slots.append({})
		pages.append(slots)


func duplicate_state() -> ActionBarState:
	var copy := ActionBarState.new()
	for page_index in range(PAGE_COUNT):
		for slot_index in range(SLOTS_PER_PAGE):
			copy.pages[page_index][slot_index] = (
				(pages[page_index][slot_index] as Dictionary).duplicate(true)
			)
	return copy


func get_slot(page: int, index: int) -> Dictionary:
	if page < 0 or page >= PAGE_COUNT or index < 0 or index >= SLOTS_PER_PAGE:
		return {}
	return pages[page][index]


## Пустой payload = очистить слот (тот же приём, что пустое имя в
## SetElementNameCommand сбрасывает custom_name на авто-подпись).
func set_slot(page: int, index: int, payload: Dictionary) -> bool:
	if page < 0 or page >= PAGE_COUNT or index < 0 or index >= SLOTS_PER_PAGE:
		return false
	pages[page][index] = payload.duplicate(true)
	return true


func to_dict() -> Dictionary:
	var rows: Array = []
	for page_index in range(PAGE_COUNT):
		var page_rows: Array = []
		for slot_index in range(SLOTS_PER_PAGE):
			page_rows.append(
				(pages[page_index][slot_index] as Dictionary).duplicate(true)
			)
		rows.append(page_rows)
	return {"pages": rows}


static func from_dict(data: Dictionary) -> ActionBarState:
	var state := ActionBarState.new()
	var rows: Variant = data.get("pages", [])
	if not rows is Array:
		return state
	var page_count: int = mini(PAGE_COUNT, (rows as Array).size())
	for page_index in range(page_count):
		var page_rows: Variant = (rows as Array)[page_index]
		if not page_rows is Array:
			continue
		var slot_count: int = mini(SLOTS_PER_PAGE, (page_rows as Array).size())
		for slot_index in range(slot_count):
			var slot: Variant = (page_rows as Array)[slot_index]
			if slot is Dictionary:
				state.pages[page_index][slot_index] = (
					(slot as Dictionary).duplicate(true)
				)
	return state
