# droptables

An Ashita v4 addon for [PhoenixXI](https://github.com/phoenixffxi/Phoenix). It adds a small frame for your current target showing:

- its **era loot table**, with each drop's chance at **treasure hunter 0 to 4**. Your own TH column is highlighted, and it's worked out from your job, level and gear the same way the server does it;
- what THF can **steal** from it;
- what an **NPC shop pays** for each drop;
- how many of that mob **you and your party have killed**, this session and in total, and the drops you actually got from those kills (with an observed rate next to the listed chance).

Nothing is ever sent to the server: droptables only reads client memory and incoming packets.

## Installation
- Download `droptables0.1.zip` from the [latest release](https://github.com/relliko/droptables/releases/latest) and extract it into your Ashita v4 directory (it contains `addons/droptables`).
- Type `/addon load droptables` in game.

## Usage
Target a mob to see its frame. Drag the frame to move it.

| Command | |
|---|---|
| `/dt on\|off` | show or hide the frame (`/droptables` works too) |
| `/dt th auto\|0-8` | your treasure hunter level; `auto` works it out from job, level and gear |
| `/dt fade [seconds]` | fade the frame out that long after you target a mob (6 s by default) |
| `/dt show always\|fade\|hold` | keep it up, fade it out, or show it only while you hold a key |
| `/dt key <key>` | the key for `hold` (shift, ctrl, alt, a-z, 0-9, f1-f12) |
| `/dt kills` | kills in this zone, this session and lifetime |
| `/dt reset session` | clear this session's counts; `/dt reset` moves the frame back |
| `/dt debug` | what the frame knows about your target |

Kills count when you, a party or alliance member, or one of your pets defeats the mob, or when your party had it claimed. Kills and drops are grouped by mob name and zone.

## Where the numbers come from
The data in `data/` is generated from PhoenixXI's own server repository by `tools/gen_loot.py`: its era drop lists (with Phoenix's drop fixes and era removals applied), the server's drop roll, its treasure hunter table and caps, and the NPC sell prices. The script's header explains how the server rolls drops.

- Treasure hunter procs are disabled on PhoenixXI, so a mob's TH is the highest TH of anyone who acted on it (capped at 8 for a THF main, 4 otherwise).
- Beastmen's seals, crystals and other drops added by the server's code aren't in the loot tables; drops you get that aren't listed show under "Also seen".
- The drop rate multiplier is Phoenix's default setting (1); the live server's own settings aren't public.

To regenerate the data from a Phoenix checkout:
```
python tools/gen_loot.py --phoenix C:\path\to\Phoenix
```
