# Electronics module plan — "AutoCAD just for electronics"

Precision CAD tool to build computer, phone, monitor/TV and audio circuits: schematic,
simulation and board design in the same project. Used with mouse, tablet and drawing pen.
Physical bench catalog: [CATALOGO.md](CATALOGO.md).

## Layout

- `backend/` (`agent-eletronica`, `/api/eletronica`, VPS): projects with `versao` (409 when another device
  saved first), component library, netlist, ERC/DRC, exports (KiCad, Gerber, drill, BOM).
- `worker/` (PC): ngspice simulation (operating point, transient, AC, sweep); later Freerouting.
- `app/` (`agent_eletronica`): CAD screen with the **Schematic**, **Board** and **Simulation** modes.

## CAD screen

- Integer coordinates in micrometers (µm); the screen shows mm or mils. Default grid of 1.27 mm (50 mil).
- Grid, snap (pin, wire end, grid), orthogonal wire, layers, 90° rotation, mirroring, undo/redo.
- Mouse: left places/selects, middle/right drags, wheel zooms, CAD shortcuts (R, C, D, W, L, T…).
- Tablet and pen: the tip places, hovering shows the preview, the finger drags and pinches, toolbar
  and big buttons instead of the keyboard.

## Library

Own base (symbol, pins, properties, prefix) with the most used components; later, import of
the official KiCad libraries (`.kicad_sym`, `.kicad_mod`) and SPICE models per component.

## Phases

1. **Core and schematic**: CAD screen, base library, wires, named nets (labels and power
   symbols), several sheets, parts list, PNG/PDF export.
2. **ERC and calculators**: loose pin, shorted outputs, net without ground; Ohm, divider, LED, RC, crossover,
   dissipation.
3. **Simulation**: netlist → ngspice on the worker; probes on the schematic, virtual oscilloscope and
   multimeter.
4. **Board**: footprints, ratsnest from the schematic, traces on 2–4 layers, vias, ground plane,
   DRC, Gerber + drill + BOM/pick-and-place for JLCPCB.
5. **Extras**: autorouting, 3D view, KiCad exchange, ready-made templates (ATX supply, VRM, phone
   charging, backlight, class D amplifier).
