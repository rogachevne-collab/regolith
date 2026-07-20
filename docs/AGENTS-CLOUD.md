# Cursor Cloud / headless VM — нюансы окружения

Дополнение к `AGENTS.md`. Актуально только при работе в облачной VM
(headless Linux без GPU/звука). Локально на macOS — не нужно.

Среда (движок + Voxel-бинарники) ставится update-скриптом на старте VM. `godot`
уже в `PATH` (`/usr/local/bin/godot`, stock 4.8), поэтому `run.sh` находит его сам.

- **Первый запуск в сессии:** `.godot/` (кэш импорта) и `addons/zylann.voxel/bin/`
  в `.gitignore`. Update-скрипт восстанавливает Voxel-бинарники, но кэш импорта —
  нет. Если `.godot/` отсутствует, один раз выполни `./run.sh --headless --import`
  перед прогоном тестов/игры (см. README).
- **Рендер/звук:** нет Vulkan-драйвера — Godot падает на OpenGL 3 (llvmpipe,
  софт-рендер) и dummy-audio. Соответствующие `ERROR/WARNING` (VK_KHR_surface,
  ALSA, SDFGI) при старте безвредны, игра рендерит корректно.
- **GUI-запуск:** дисплей `:1`. Запускай окно как `DISPLAY=:1 ./run.sh res://scenes/main.tscn`.
- **Smoke `main.tscn`:** planetoid default; для headless-проверки
  компиляции шейдеров/скриптов ограничивай кадры: `./run.sh --headless res://scenes/main.tscn --quit-after 300`
  Legacy flat yard: `res://scenes/flat_moon.tscn`.
  (предупреждения «ObjectDB instances leaked at exit» при таком выходе — норма).
- **Бур:** карвит voxel-terrain только под прицелом в пределах `reach = 2.2 м`
  (`scripts/drill.gd`); чтобы прорыть грунт под ногами, смотри почти строго вниз.
- **Автоматическое GUI-тестирование (computer-use):** при захваченной мыши
  относительное движение (`InteractionEventMouseMotion.relative`) в `mouse_look.gd`
  срабатывает нестабильно, поэтому точное прицеливание для бурения через
  computer-use ненадёжно; проще подойти WASD вплотную к склону в пределах reach.
  Код игры при этом НЕ править.

## Историческая справка

**PoC 1–3 ✓** — cart 1a–1c, structural rebuild, passenger.
**PoC 4+** — actuators, electric network, cargo, atmospheres (см. CONCEPT roadmap).

Erebus-порт R0/R1 заморожен в репозитории Erebus; целевая интеграция — Erebus Lite addon.
