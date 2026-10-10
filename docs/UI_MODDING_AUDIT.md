# Runtime UI modding audit and implementation report

## Scope and result

The engine already uses its established Paradox-style text format under `game/interface/` for **global themes**, **custom mechanic panels**, and **custom map modes**. This change adds shared HUD container metrics to the existing theme format, plus explicit, backwards-compatible `override`, `extend`, and `disable` operations for custom panels, with stable-ID matching, partial metadata patches, validation, CLI self-tests, and an example mod.

It does **not** migrate the engine's built-in HUD screens into per-component data definitions. Shared top-bar height, left menu width, left-panel width, and right-panel width are now configurable without changing defaults; individual widget placement, spacing, labels, visibility, state styles, and gameplay bindings remain code-authored. Extracting those widgets is a larger next step because screens call game systems directly and share focus/selection/tool state with immediate-mode handlers. This patch does not claim the broader HUD migration is complete.

## Repository and engine findings

- Runtime: C#/.NET 8; game uses raylib and a small immediate-mode GUI (`src/Burger.Game/Gui.cs`); Burger Studio is a separate Dear ImGui application (`src/Burger.Studio/`).
- Data language: Paradox-like `.txt`, parsed to `Node`; directory definitions use `DataLoader.ParseFileOrFolder` and recursive filename sorting.
- Interface loader: `src/Burger.Core/Mechanics/Interface.cs`, loaded from `DataLoader.LoadDefinitions`.
- Mod hooks: `game/scripts/*.cs` compile at runtime through `ModManager`; project `backend/*.cs` holds game rules. There is no separate package/manifest-based runtime UI mod loader or global mod-priority system.
- UI assets: paths such as `gfx/fonts/...`, `gfx/interface/...`, and icons are resolved relative to the game root. Theme fonts try configured paths, then `gfx/fonts`, engine fonts, and system fonts. Missing panel icons fall back to initials; missing panel/button textures fall back to drawn panels/buttons. A missing configured body font logs a warning.
- Definitions are hot-reloadable via the game reload path documented in `docs/MODDING.md` (or restart); runtime reload behavior for active partial-panel references was not independently exercised here.

## UI surface map

| Surface | Current implementation | Modding status |
|---|---|---|
| Main game theme | `interface/theme.txt` -> `ThemeDef` -> `Gui.ApplyTheme` | Data-driven colors, fonts, font/UI scale, ornate style, 9-slice textures, and shared HUD container metrics (`top_bar_height`, `left_menu_width`, `left_panel_width`, `right_panel_width`); later entries apply over earlier field/color/metric values. |
| Custom panels | `interface/*.txt`, `PanelDef` / `PanelElement`, rendered by `Hud.Mechanics.cs` | Data-driven title/button/hotkey/width/icon/visibility, ordered text/header/separator/button/bar/list content; safe script triggers/effects. Now supports explicit partial override, extension, and disable by panel ID. |
| Custom map modes | `interface/*.txt` -> `MapModeDef` | Data-driven name, value formula, range, and low/high colors; duplicate definitions replace by ID. |
| Top bar, built-in left/right panels, event/proposal/error/save/pause modals, notifications, selected-unit overlays | `Hud*.cs` and `App.cs` | Shared major container dimensions are theme-configurable; individual widget layout and draw/input/gameplay handlers remain code-authored. Theme styles/colors apply to common rendering primitives. |
| Tooltips/contextual info | In draw/input handlers, commonly `Gui.Tooltip` | Content and placement are code-authored except custom panel element tooltips. There is no generic context-menu definition format. |
| Selection, drag/drop, map click/right-click, box selection, orders, focus | `App.cs`, `Hud.cs`, `UiState.cs`, `CameraController.cs` | Gameplay-bound code. Not migrated or changed. |
| Hotkeys | `Hud.HandleKeys`, `Hud.Mechanics.HandleMechanicKeys`, `CameraController` | Built-in bindings are code-authored; custom panels already define a hotkey parsed as a `KeyboardKey` name. Invalid custom hotkey names are ignored by current dispatch. |
| Burger Studio panels | `src/Burger.Studio/Studio*.cs` | Separate editor UI, not runtime game interface definitions. Not changed. |

## Definition and override semantics

All definitions live in the existing `game/interface/` directory, in `.txt` files; there is no new mod manifest or alternate parser. The root `interface.txt` (if present) is read before files under `interface/`; files are then processed in case-insensitive filename order. Therefore later definitions have later precedence.

- A panel's explicit `id` is its stable identifier. Matching is case-insensitive. A legacy panel without an ID still gets a line-derived ID and a warning; do not use that fallback for overrides.
- A repeated panel ID without an operation retains legacy behavior: the later full definition replaces the earlier panel.
- `override = yes` updates only the panel properties explicitly supplied (`title`/`name`, `button_text`, `hotkey`, `icon`, `potential`, `width`). Unspecified properties and the existing element sequence remain untouched. If element declarations are included, that list replaces the panel's element sequence.
- `extend = yes` updates any explicitly supplied panel properties and appends declared elements in order.
- `disable = yes` removes a panel with that ID. This only disables data-driven custom panels; it does not hide built-in engine screens.
- Exactly one operation may be used per definition. An override/extension/disable for an unknown ID logs an error and leaves other definitions intact.
- `width` is an integer from 200 to 1000 layout units. Invalid values report a file/line diagnostic and use the safe default on a new panel or retain the existing value for a patch.
- `potential`, element `potential`/`allow`, and button `effect` remain the engine's existing script AST/trigger/effect system. No arbitrary serialized code is introduced; simulation and action semantics stay in engine code.
- Theme properties, individual named colors, and known layout metrics merge field-by-field in file order; omitting a property preserves its previous/default value. Metric defaults are 46 (top bar), 78 (left menu), 390 (left panel), and 420 (right panel) layout units. Known values must be numeric from 20 to 1000; unknown names and invalid values are diagnosed and preserve safe defaults/previous values.

Supported panel properties are `id`, `title` (or alias `name`), `button_text`, `width`, `icon`, `hotkey`, and `potential`. Content elements are `text`, `header`, `separator`, `button`, `bar`, and nested `list`; their existing fields include text/tooltips, `potential`, button `allow`/`effect`, bar `value`/`min`/`max`/`color`, and list `iterator`/`limit`/`max_rows`/children. Custom panel content is ordered; currently there are no stable IDs for individual child elements.

### Minimal example

```text
panel = {
    id = court
    title = "Royal Court"
    button_text = "Court"
    width = 420
    text = "Ruler: [ROOT.ruler]"
}
```

### Partial override

```text
panel = {
    id = court
    override = yes
    title = "Royal Council"
    width = 460
}
```

The existing button text, visibility, and elements survive.

### Extension

```text
panel = {
    id = court
    extend = yes
    header = "Additional information"
    text = "Appended content"
}
```

### Disable

```text
panel = { id = court disable = yes }
```

A complete copyable example is in [`examples/ui-partial-override/game/interface/10_court_patch.txt`](../examples/ui-partial-override/game/interface/10_court_patch.txt). It targets the `court` panel already present in SampleGame.

To tune one shared HUD region while leaving every other default intact:

```text
theme = {
    layout = {
        left_panel_width = 430
    }
}
```

## Validation and fallback

- Unknown top-level interface entries continue to be logged with source location.
- Missing override targets, conflicting operations, missing stable IDs for operations, and invalid widths are diagnosed rather than crashing the loader.
- Missing optional textures and icons are tolerated by existing runtime fallbacks; configured missing body fonts produce a warning and font fallback. Texture lookup is relative to the game folder.
- Use `burger validate <project>` for normal project validation. `burger validate <project> --selftest` includes regression checks for vanilla loading, field-level patch retention, extension, sorted-file precedence, disable, and malformed definitions.

## Verification status

- Repository/engine/UI/modding audit: completed by source inspection.
- `dotnet build BurgerEngine.sln -c Release`: **passed**, 0 errors. A full rebuild emitted 4 pre-existing warnings (missing XML parameter documentation, unused map field, nullable warning, and unused Studio field; none are in the changed code); the final incremental build emitted 0 warnings.
- `burger validate SampleGame --selftest --days 1`: **passed**. This included the new vanilla/property-patch/extension/disable/order/theme-metric/invalid-definition checks, existing save/load and simulation tests, and combat/feature tests. Expected diagnostic errors from deliberately malformed interface fixtures are asserted and excluded from the final pass/fail count.
- `burger validate SampleGame --days 60`: **passed**, 0 errors and 0 warnings.
- Hidden Raylib launches succeeded and captured 1600×900 screenshots for observer mode and player `VAL` with the built-in military panel open. The player capture visually confirms the top bar, left menu, military panel, map/unit overlays, and map-mode strip render. A temporary copy of SampleGame with only `left_panel_width = 500` rendered a visibly wider military panel (about 105 px); the default capture retains the prior 390-unit width. See [default HUD smoke capture](ui-modding-smoke-default.png) and [500-unit panel capture](ui-modding-smoke-left-panel-500.png). These are post-change smoke captures, not pixel comparisons to a pre-change baseline.
- `Gui` defaults match the previous hard-coded dimensions, and no gameplay action/input handler was intentionally changed beyond reading those defaults. Interactive mouse/keyboard behavior and exact visual equivalence to a pre-change run remain unproven; verify them before any reskin.
- Untested edge cases include hot-reloading while a custom panel is open, texture decoding failures, and interactive focus/keyboard/mouse behavior on a normal graphical session.
