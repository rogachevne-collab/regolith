class_name SetElementNameCommand
extends RefCounted
## Переименование экземпляра элемента оператором (CONTROL-ACTIONS-V0).
## Доставка надёжная и упорядоченная (как у структурных), но топологию не меняет:
## эффект — bump `SimulationElement.state_revision`, не `Assembly.revision`.

## Пустое имя сбрасывает на авто-подпись (display_name архетипа + тег).
const MAX_LENGTH := 48

var element_id: int = 0
var element_name: String = ""


func kind() -> StringName:
	return &"set_element_name"


## Нормализация до применения: обрезка пробелов, переносов и длины.
static func sanitize(raw: String) -> String:
	var clean := raw.replace("\n", " ").replace("\t", " ").strip_edges()
	if clean.length() > MAX_LENGTH:
		clean = clean.substr(0, MAX_LENGTH).strip_edges()
	return clean
