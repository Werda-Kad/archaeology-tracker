# Where the game stores archaeology data

Found with archaeology-probe (rounds 1-2) and `pan` output in `Probe output.txt`.
In that file, a negative id is a "VarBit": a small value packed inside a bigger one.
Line format: `id NAME TYPE baseVarId mask`.

## Storages (inventories)
Only readable while open. Closing removes them. The tracker must save a copy each time one opens or changes.

| Storage | Inv name (id) | Sent when |
|---|---|---|
| Backpack | `INV` (93) | Always |
| Bank | `BANK` (95) | Bank opened |
| Artifact storage | `ARCH_RESTORATION_WORKBENCH_STORAGE` (1008) | Workbench or artifact storage opened |
| Material storage | `ARCH_MATERIAL_STORAGE` (885) | Workbench or material storage opened |
| Soil box | `ARCH_SOIL_BOX` (884) | Opened with the workbench |

Restoring while material storage is closed sends no material update. Counts catch up when it reopens.
Depositing with the right-click option (storage closed) does send a material storage update (Tyrian purple 1 -> 13).
Counts checked by hand against the game for gladius, venator dagger, hallowed lantern and their ingredients: all correct.

## Saved values (VarPlayer / VarBit)
| Data | Name pattern | Example |
|---|---|---|
| Artifact in a collection (on/off) | `COLLECTION_<COLLECTOR>_<NN>_ARCH_<ARTIFACT>` | `COLLECTION_VELUCIA_01_ARCH_VENATOR_DAGGER` |
| Collection ever completed (on/off) | `COLLECTION_<COLLECTOR>_<NN>_COMPLETE` | `COLLECTION_VELUCIA_19_COMPLETE` |
| Times an artifact was restored (lifetime) | `ARCH_RESTORATION_<ARTIFACT>` | `ARCH_RESTORATION_LEGIONARY_GLADIUS` |
| Total restorations / discoveries | `ARCH_RESTORATION_TOTAL`, `ARCH_DISCOVERY_TOTAL` | |
| Mystery completed (on/off) | `ARCH_MYSTERY_<SITE>_<NAME>_COMPLETED` | `ARCH_MYSTERY_DAEMONHEIM_A_NEW_HOME_COMPLETED` |
| Mystery progress step | `ARCH_MYSTERY_<SITE>_<NAME>` | |
| Relic unlocked / acquired | `ARCH_RELIC_<NAME>_UNLOCKED`, `_ACQUIRED` | `ARCH_RELIC_WOLFS_HUNGER_UNLOCKED` |
| Active relic loadout (0-3) | `ARCH_RELIC_LOADOUT` | |
| Relic in each loadout slot (number id) | `ARCH_RELIC_LOADOUT_<L>_SLOT_<S>_ID` | Number = `ARCH_RELIC` table column 1 |
| Dig site unlocked | `ARCH_SITE_UNLOCK_LETTER_<SITE>` | Probably |

## Reading values
`var.VarPlayer.<NAME>.value` returns the unpacked value directly, VarBits included (round 3: all 11 tested names matched).
The `_COMPLETE` flag means "completed at least once"; it stays on while the collection refills.

## Reference data inside the game (round 4)
Items can be found by scanning `config.Obj.FromID(0..70000)` (~21 s at 2000 per tick) and checking `category`:

| Category | Meaning | Count found |
|---|---|---|
| 4608 `ARCH_RESTORATION_DAMAGED` | Damaged artifacts | 238 |
| 4609 `ARCH_RESTORATION_RESTORED` | Restored artifacts | 247 |
| 4602 `ARCH_MATERIAL` | Materials | 47 |

Restored artifacts carry their recipe as params:
- `RECIPE_INGREDIENT_TYPE_n` / `RECIPE_INGREDIENT_NUMBER_n`: ingredient 1 is the damaged artifact, the rest are materials and amounts.
- `RECIPE_REQUIREMENT_TYPE_n` / `_VALUE_n`: type 28 with value = level (gladius: 12). Type 64 unknown.
- `RECIPE_XP_VALUE_1`: restoration XP (gladius: 4308).

Materials carry: `USE_REQUIRES_STAT_LEVEL1` (level), `ARCH_EXCAVATION_DATA` (links to its hotspot/cache row), `ARCH_CULTURE` (some only), `GE_CATEGORY`.
Internal names link everything: `ARCH_LEGIONARY_GLADIUS` (restored), `ARCH_RESTORATION_LEGIONARY_GLADIUS_DAMAGED`, collection flag `..._ARCH_LEGIONARY_GLADIUS`.

## Data tables (round 5)
Read with `config.DBRow.FromID(id)` and `row:GetColumnValues(column)`. Row ids run 89-20203 with no big gaps; `row.ownerDBTable.configName` says which table. `archaeology-tracker/catalog.lua` scans them at startup.
Row names are in `Probe output 2.txt`. "?" = meaning not confirmed yet.

| Table (rows) | Known columns |
|---|---|
| `COLLECTION` (185) | 5 name ("Museum - Zarosian I"), 14 artifacts (restored items). ? 1, 3, 6, 10/12 achievement |
| `COLLECTOR` (14) | 2 name, 5 quote, 6 location text ("Archaeology Guild"), 8 collection log. ? 1, 7 (list 1-7) |
| `ARCH_SITE` (92) | 3 name, 4 description, 14 soil, 15 material list, 16 restoration list, 17 hotspots. ? 1, 2, 7, 9 |
| `ARCH_EXCAVATION` (149) | 3 name, 5 level, 15 soil, 16 materials + weights, 18 artifacts (restoration rows) + weights. No coordinates seen |
| `ARCH_RESTORATION` (250) | 4 description, 5 level, 6 damaged item, 7 restored item. ? 1, 3 (gladius: 11084) |
| `ARCH_MYSTERY` (52) | 2 name, 3 level?, 4 dig site. ? 1 |
| `ARCH_RELIC` (33) | 1 relic number (4 = Endurance, matches loadout slots), 2 name, 3 effect, 6 monolith energy cost (50/100), 7-8 icon, 9 large icon, 10 relic item (its DESTROYONDROP_MES says where to reclaim it). No level or source (round 19). Loadouts have 4 slots; 0 = empty. |

Others: `ARCH_RESEARCH`, `ARCH_RESEARCHER`, `ARCH_QUALIFICATION`, `ARCH_TOOL_STATS`, `COLLECTION_LOG`.

Dig sites: only the 9 rows named `ARCH_SITE_*` are dig sites; the other 83 `ARCH_SITE` rows
(`ARCH_EXCAVATION_SITE_*`) are their sub-areas. A site's column 16 is an enum of its artifacts
(e.g. `ARCH_KHARIDET_RESTORATION_LIST`); column 17 lists its sub-areas and hotspots.

Sub-areas list their hotspots in column 18 (sites use 17). Hotspot rows: 1 id?, 2 type? (1 = hotspot),
3 name, 5 level, 15 soil, 16 materials + weights, 17 lore pages + weights, 18 artifacts + weights.
No hotspot row holds a map coordinate (round 11). Site column 9 is the site's banner image
(SPRITE, e.g. ARCH_SITE_BANNER_KHARIDET); column 10 its icon (STRUCT ARCH_SITE_ICON_*).
Round 12 confirmed it table-wide: neither ARCH_SITE nor ARCH_EXCAVATION has any tile (COORDGRID)
column. ARCH_SITE column types: 1-2 INTEGER, 3-4 STRING, 5 BOOLEAN, 7-8 INTEGER, 9 SPRITE, 10 STRUCT,
13 NPC (site manager), 14 OBJ (soil), 15-16 ENUM, 17-18 DBROW. Sub-area rows: 1 id, 2 = 2, 3 name
("Kharid-et - Barracks excavation site"), 7 level, 18 hotspots.
The only archaeology tiles in the game data are Orthen's 5 areas (`ARCH_ORTHEN_SITE_MAP_LIST`, names in
`ARCH_ORTHEN_SITE_NAME_LIST`), e.g. Crypt of Varanus (5317, 2410, level 0).

## Hotspot locations (round 11)
Hotspots are objects in the world ("locs"). `LocList.ByName(name)` / `LocList.All()` return the ones
loaded near you, each with its exact `coordGrid` tile; `Event.LocAdded` fires as they load.
Venator remains = loc id 117101, 3 copies at Kharid-et (3370,3189), (3371,3193), (3376,3188).
A 3D arrow (ShapeInstance, yaw in degrees, 0 = +Z, `math.atan(dx, dz)`) over the player pointed correctly.

## World map (from `Probe output 4.txt`: `pan Interface` and `pan Component`)
Interface `WORLDMAP_V2_UI` (component ids 93192192+): `MAINWIN` (map area), `WORLDMAP_OVERLAY`,
`YOU_ARE_HERE` (player marker), `ZOOM_LEVEL`, `FINDBOX` (map search box), `ARROW_WAYPOINT`.
No API opens or moves the map; untested whether these can be read or drawn over.

## Enums (from `Probe output 2.txt`)
| Enum | Holds |
|---|---|
| `ARCH_RESTORATION_TABLE_LIST` | The per-culture artifact lists below |
| `ARCH_RESTORATION_TABLE_NAMES` | Their display names (same numbering) |
| `ARCH_RESTORATION_<CULTURE>_TABLE` | Artifacts of one culture: ZAROSIAN, ZAMORAKIAN, SARADOMINIST, ARMADYLEAN, BANDOSIAN, DRAGONKIN, GUTHIXIAN, MISCELLANEOUS |
| `ARCH_<SITE>_RESTORATION_LIST` / `_MATERIAL_LIST` | A dig site's artifacts / materials |
| `ARCH_COLLECTOR_COLLECTION_LIST` | Collector -> collections (not used yet; could replace name matching) |
| `ARCH_MATERIAL_CULTURE_LIST` | Material -> culture number (not used yet) |

## Still unknown
- Chronote rewards: not in the game data (round 14); learned as you play by chronotes.lua.
- Hotspot and collector map coordinates: not in the sampled columns.
- How to obtain each relic (step-by-step text): wiki only.
- Static data (recipes, hotspots, collectors, levels, chronote rewards): not in this list; plan is a bundled data file.

## Collections and chronotes (round 14)
- `COLLECTION` columns: 1 id, 3 tier?, 5 name, 6 two flags, 10 achievement, 12 achievement struct (name, RuneScore), 14 artifacts (restored items).
- `COLLECTOR` columns: 2 name, 3 NPC (e.g. `ARCH_COLLECTOR_VELUCIA`; usable to find them in the world), 5 quote, 6 location text, 7 list 1-7 (unknown), 8 collection log row.
- Chronote rewards are stored nowhere we can read: not on collections, artifacts (damaged or restored) or the `CURRENCY_CHRONOTES` row (which only names the chronote item, `ARCH_CURRENCY_CHRONOTES`). Known values: Museum - Zarosian I gives 2635 on completion; Legionary square shield about 220 when handed in.
- Restored artifacts hold their recipe as settings (RECIPE_INGREDIENT_*, RECIPE_XP_VALUE_1 = XP x10).
- Seen in game (Museum - Zarosian I): dagger 206, light crossbow 206, Primis Elementis 220, gladius 220, square shield 220, Zaros effigy 244, training dummy 244, Legatus figurine 274; the last hand-in paid 2909 (its own reward plus the 2635 completion bonus in one backpack update).
- Each hand-in's museum flag and its chronotes arrive together, about 2 s apart when handing in one by one.
- The collector's collection window is interface 656 (`COLLECTION_LOG`), not `COLLECTOR_BOARD` (round 16). Its text is readable: every collection name of that collector, then the chosen collection's name again, "Reward: N Chronotes" and "Contribute All". Only the chosen collection's reward is shown. chronotes.lua reads it every tick (0.6 s) while open.

## Caches and unlisted hotspots (round 17)
- 46 `ARCH_EXCAVATION` rows have no name: the material caches. Column 2 is the kind of spot (1 hotspot, 2 cache); column 16 their one material.
- Caches are listed in sub-areas' column 18 like hotspots, some in several sub-areas (e.g. Keramos in Everlight's graves and artisan areas).
- A few sub-areas belong to no dig site: `ARCH_EXCAVATION_SITE_VARROCK_EAST` (Third Age iron cache), `..._ALKHARID_EAST` (Samite silk), `..._ICE_MOUNTAIN` (White oak).
- Some hotspots are in no area list, e.g. Fort debris (`ARCH_EXCAVATION_KHARIDET_ENTRANCE_DEBRIS`); their row name includes the site.
- Each site's column 15 is its material list (enum of material items).

## Guild qualifications (rounds 20-21)
- `ARCH_QUALIFICATION` table: 1 number (1 Intern ... 5 Guildmaster), 2 name, 3 icon, 4 its achievement, 6 rewards text.
- `ARCH_QUALIFICATION` (saved value): your current qualification (0-5).
- Each qualification's achievement has `CHEEVO_META_LIST`, the achievements needed first. Each has a target
  (`CHEEVO_CHECK_VAR_TOTAL`) and a chain (`CHEEVO_PARENT_CHAIN_LATEST`) saying which stat it counts:
  `CHEEVO_ARCHAEOLOGY_CHAIN` level, `_DISCOVERY_CHAIN` uncovered, `_RESTORATION_CHAIN` restored,
  `_COLLECTION_CHAIN` unique collections completed, `_MYSTERY_CHAIN` mysteries, `_RESEARCH_CHAIN` research hours.
- Targets (October 2026): Assistant 40 / 25 / 25 / 1 / 1; Associate 70 / 250 / 250 / 5 / 10 / 24 h;
  Professor 90 / 500 / 500 / 20 / 15 / 72 h; Guildmaster 99 / 1000 / 1000 / 25 / 20 / 168 h.
- Totals: `ARCH_DISCOVERY_TOTAL` (uncovered), `ARCH_RESTORATION_TOTAL` (restored), `ARCH_CONTRIBUTION_TOTAL`,
  `ARCH_DONATION_TOTAL`, `ARCH_RESEARCH_TOTAL_TIME` (in game ticks of 0.6 s: 6000 an hour; it rose by a research's length when its report was inspected).

## Research team (rounds 22-23)
- One assignment at a time: `ARCH_RESEARCH_CONTRACT_1_RESEARCH_ID` (0 = none, assumed), `_RESEARCH_LEVEL`,
  `_RESEARCHER_1_ID` to `_5_ID`. `_ASYNCH_ID` is 1 while the team is out and 0 once its report is ready.
- Nothing counts down: the time left isn't saved anywhere a plugin can read. The research window
  (interface 693, `ARCH_RESEARCH_MANAGEMENT`) shows it as text, e.g. "Report ETA: 46m".
- `ARCH_RESEARCH` table: 1 number, 3 dig site, 4 name, 7-8 descriptions, 9 length in game ticks (6000 = 1 hour),
  11 the lengths offered for general research (hours: 2, 4, 8, 12, 24).

## Research window images (round 25)
- Mission card: the dig site's banner (`ARCH_RESEARCH_SITE_BANNER_<SITE>`, 385 x 90, culture symbol included) with
  `..._GENERAL` (10286) or `..._SPECIAL` (10287) drawn over it; Archaeology symbol 10782 with "Lvl N"; hourglass 14885.
- Bevelled panel frame: 18081-18086 (top row and middle row), 23881-23883 (bottom row).

## Chronote values (RuneScape Wiki)
- Each artifact has a fixed reward (its wiki page's `chronotes`); the same in every collection it's in.
- Completing a collection pays a bonus equal to its artifacts' total; 125% for Velucia's museum collections
  (confirmed: Museum - Zarosian I's nine add up to 2,108, and the game paid 2,635 = 2,108 x 1.25).
- The museum donation bin pays 40% of an artifact's reward.
- `core/chronote_values.lua` ships the wiki's values; rewards seen in game replace them.

## Tetracompass (round 26)
- `ARCH_RESTORATION_TETRACOMPASS`: level 50, no damaged item (column 6 empty); column 7 is `Tetracompass (unpowered)`,
  whose recipe is the four pieces (`ARCH_TETRACOMPASS_PIECE_1`-`4`, one each) and 30 each of malachite green,
  cadmium red, cobalt blue, Armadylean yellow and Tyrian purple; 2,065 XP.
- `ARCH_EXCAVATION_TETRACOMPASS`: kind 3, level 50, no drop list (where the pieces come from isn't in this row).
