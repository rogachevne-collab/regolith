# Vertical Slice 01 — Industrial Base

Статус: production milestone после закрытия PoC 1–3.

Родительские документы:

- `docs/CONCEPT.md` — продуктовая цель и core loop;
- `docs/PHYSICAL-LANGUAGE.md` — доменный контракт;
- `AGENTS.md` — процесс и Definition of Done.

## Цель

Собрать первый короткий, но законченный игровой цикл:

```text
ручное действие
  → строительство закреплённой базы
  → стационарная добыча
  → хранение и переработка
  → изготовление компонента
  → расширение или ремонт базы
```

Slice проверяет не отдельную машину, а общий язык мобильных и стационарных
конструкций. Ровер может участвовать в доставке, но прохождение не должно зависеть
от уникального кода ровера.

Целевая длительность первого прохождения — 20–30 минут без обучения вне игры.

## Опыт игрока

Игрок появляется на промышленной площадке с ручным буром, сварочным инструментом,
небольшим стартовым запасом компонентов и понятной ближайшей задачей.

Он должен:

1. Осмотреть площадку и понять доступные действия без чтения логов.
2. Поставить `Anchor/Foundation` и несколько каркасов элементов.
3. Заварить каркасы, расходуя стартовые компоненты.
4. Соединить источник энергии, стационарный бур, хранилище, переработчик и
   fabricator.
5. Запустить добычу typed ore из зоны террейна (фон или линза; канон —
   `TERRAIN-MATERIALS-V1.md`).
6. Получить через цепочку стройкомпонент (`plate_*` / `girder` / `mechanism`).
7. Построить дополнительный элемент базы или восстановить повреждённый.
8. (Расширение loop) получить `water` и прогнать через отдельный `electrolyzer`
   в `oxygen` + `hydrogen`.
9. Увидеть однозначное подтверждение завершения цикла.

## Границы slice

### Player & Interaction v1

Контроллер является production-системой, а не временным способом добраться до
оборудования.

Обязательно:

- `CharacterBody3D` с физической капсулой и единицами СИ;
- отзывчивые разгон, торможение, air control и прыжок при лунной гравитации;
- устойчивое движение по неровному voxel terrain, небольшим ступеням и склонам;
- отсутствие camera jitter на земле и движущихся `Body`;
- наследование platform velocity при движении, прыжке и сходе;
- независимые physics body, camera look и audiovisual motion;
- чувствительность мыши и FOV как настройки, без зависимости от FPS;
- единый interaction query от камеры с явной точкой и типом цели;
- короткое действие по нажатию и продолжительное действие с cadence;
- paged toolbar: бур, сварка и construction archetypes на стартовой странице;
- ортогональный 3-axis поворот preview (24 `OrientationUtil` ориентации);
- подсветка цели, допустимость действия и результат (без progress bar для weld);
- инструменты не выполняют мутацию напрямую, а отправляют доменную команду.

Ручная feel-проверка обязательна: 15 минут перемещения, строительства и работы
инструментами не вызывают непреднамеренного скольжения, потери цели, рывков камеры
или необходимости бороться с контроллером.

### Construction v1

Детальный контракт: [`CONSTRUCTION-V1.md`](CONSTRUCTION-V1.md).

Жизненный цикл элемента:

```text
preview → frame → operational
            |          |
            └──────────┴→ damaged → broken
                                  ↓
                         repaired / dismantled
```

Состояния разделены:

- `build_progress` — доля завершения строительства;
- `integrity` — текущая прочность относительно максимальной;
- `condition` — долговременный износ и эффективность; не симулируется в Slice 01,
  но не подменяется `integrity`.

Правила:

- archetype задаёт bill of materials элемента;
- placement валидирует позу, расходует первый обязательный компонент и создаёт
  только `frame`;
- `weld` переносит доступные компоненты bill of materials в каркас и повышает
  `build_progress` пропорционально внесённым материалам;
- элемент становится функциональным только при достаточном `build_progress`;
- `damage` уменьшает `integrity`, но не `build_progress`;
- `repair` восстанавливает `integrity` и потребляет ресурс;
- `broken` остаётся массой и частью структуры, но теряет функцию;
- `dismantle` возвращает явно заданную долю материалов и удаляет элемент
  структурной командой;
- placement, weld, damage, repair и dismantle не изменяют сцену в обход
  авторитетного simulation state.

### Simulation Kernel v0

Мобильная машина и стационарная база различаются композицией:

- база — `Assembly` с `Anchor`;
- машина — `Assembly` без `Anchor`;
- все элементы создаются из data-driven archetype;
- начальная конструкция задаётся `Blueprint`;
- структура меняется только упорядоченными structural commands;
- simulation state владеет элементами, ресурсами и состояниями;
- physics projection строит тела и коллайдеры из simulation state;
- presentation отображает состояние, но не является его источником;
- каждая функциональная система публикует `status` и `reason`.

Минимальные архетипы Slice 01:

- `foundation`;
- `frame`;
- `power_source`;
- `stationary_drill`;
- `cargo_store`;
- `processor`;
- `fabricator`.

### Industry v1 + Terrain Materials

Детальный контракт машин/сетей: [`INDUSTRY-V1.md`](INDUSTRY-V1.md).  
Канон руд, зон, рецептов, O₂/H₂, `electrolyzer`: [`TERRAIN-MATERIALS-V1.md`](TERRAIN-MATERIALS-V1.md).

Кратко — зоны террейна → typed ores → стройкомпоненты и вода/газы; cargo/electric
Flow; distributor + wire mesh; отдельный электролизер.

Обязательно:

- electric Flow: `power_source` → wire mesh → `power_distributor` (+ `power_battery`) → consumers в радиусе;
- cargo Flow по cargo-портам + ручной pickup/deposit;
- ограниченная вместимость Store (volume);
- `stationary_drill`: contact-gated carve + typed ore из измеренного объёма × материал вокселя;
- hand drill: loot pile в мире;
- processor / fabricator / **electrolyzer**: data-driven `Recipe`, atomic reserve, queue;
- остановка с reason: `no_power`, `no_input`, `storage_full`, `port_disconnected`,
  `element_incomplete`, `outside_power_radius`, `disabled`, `no_terrain_contact`.

## Последовательность реализации

1. **Player & Interaction v1** — controller, interaction query и tool action.
2. **Simulation Kernel v0** — единая модель базы и машины, archetypes и Blueprint.
3. **Construction v1** — preview, frame, weld, integrity, repair, dismantle.
4. **Industry v1** — power, cargo/storage, drill, processor и recipe.
5. **Terrain Materials v1** — зоны, typed ores, electrolyzer, O₂/H₂ (спека → код).
6. **Slice integration** — задача, диагностика, audiovisual feedback и баланс.

Каждый этап заканчивается игровым сценарием и regression-проверкой. Реализация
следующего этапа не должна обходить контракт предыдущего.

## Acceptance

Slice закрыт, когда:

1. Новый игрок без внешней инструкции завершает core loop за 20–30 минут.
2. Базу можно собрать из каркасов и заварить ручным инструментом.
3. Неполный или сломанный элемент не выполняет функцию и объясняет причину.
4. Стационарный бур добывает ресурс только при выполнении физических и сетевых
   условий.
5. Ресурс проходит Store, processor и fabricator без создания или потери при
   остановке/перезапуске.
6. Из произведённого компонента можно построить новый элемент либо починить
   повреждённый.
7. Повреждение ключевого элемента останавливает зависимую часть цепочки; ремонт
   восстанавливает работу без пересоздания всей базы.
8. Та же модель `Assembly/Element` поддерживает anchored base и существующую
   мобильную конструкцию.
9. Все мутации представлены командами, а не прямыми изменениями presentation-node.
10. Критический путь покрыт headless-тестами; существующие PoC-тесты проходят.
11. `main.tscn` проходит smoke без ошибок, orphan nodes, NaN и shader errors.
12. Входящие в slice действия имеют финальные animation/VFX/SFX и UI feedback,
    достаточные для чтения состояния без debug overlay. UI-контракт:
    [`HUD-UI-01.md`](HUD-UI-01.md).

## Не входит

- полное дерево исследований и рецептов;
- conveyors с физическими предметами;
- сложная логистическая автоматика и Control Graph
  (`docs/specs/CONTROL-GRAPH-V0.md` — post-slice);
- прочность по FEM, усталость и распространение нагрузок;
- долговременный износ `condition`;
- атмосферы и герметичные объёмы;
- кооператив и сетевой replication;
- финальный набор биомов, машин и производственных блоков;
- полировка launch vehicle и систем, не участвующих в core loop.
