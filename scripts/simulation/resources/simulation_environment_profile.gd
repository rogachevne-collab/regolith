class_name SimulationEnvironmentProfile
extends Resource

## Immutable per-location simulation configuration. This is deliberately not
## captured in SimulationSnapshot; the scene hosting SimulationSession owns it.
@export_range(0.0, 1.0) var oxygen_saturation: float = 0.0
