class_name ConfigureActionSlotCommand
extends RefCounted
## Привязка/снятие одной клавиши бара ControlSeat-хоста (CONTROL-ACTIONS-V0).
## Доставка надёжная и упорядоченная, как у структурных, но топологию не
## меняет: эффект — bump `SimulationElement.state_revision` хоста, не
## `Assembly.revision` (тот же контракт, что у SetElementNameCommand).

## Пустой payload сбрасывает слот (тот же приём, что пустое имя в
## SetElementNameCommand сбрасывает custom_name).
var host_element_id: int = 0
var page: int = 0
var index: int = 0
var payload: Dictionary = {}


func kind() -> StringName:
	return &"configure_action_slot"
