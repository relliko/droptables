# droptables

An Ashita v4 addon for [PhoenixXI](https://github.com/phoenixffxi/Phoenix). It adds a small frame for your current target showing:

- its **era loot table**, with each drop's chance at **treasure hunter 0 to 4**. Your own TH column is highlighted, and it's worked out from your job, level and gear the same way the server does it;
- what THF can **steal** from it;
- what an **NPC shop pays** for each drop;
- how many of that mob **you and your party have killed**, this session and in total, and the drops you actually got from those kills (with an observed rate next to the listed chance);
- a **seal timer**: how long since a Beastmen's or Kindred's Seal last came into your treasure pool, how many kills since, and whether one can drop yet.

Nothing is ever sent to the server: droptables only reads client memory and incoming packets.

## Installation
- Download `droptables0.1.zip` from the [latest release](https://github.com/relliko/droptables/releases/latest) and extract it into your Ashita v4 directory (it contains `addons/droptables`).
- Type `/addon load droptables` in game.

## Usage
Target a mob to see its frame. Drag the frame to move it. The `-` at the end of its first line minimizes it to a small chest icon at the bottom right of the screen, in one row with the minimized windows of allrecipes, deeps and scouter; click the icon (or `/dt on`) to bring it back.

| Command | |
|---|---|
| `/dt on\|off` | show or hide the frame (`/droptables` works too) |
| `/dt min` | minimize the frame to its icon |
| `/dt th auto\|0-8` | your treasure hunter level; `auto` works it out from job, level and gear |
| `/dt fade [seconds]` | fade the frame out that long after you target a mob (6 s by default) |
| `/dt show always\|fade\|hold` | keep it up, fade it out, or show it only while you hold a key |
| `/dt key <key>` | the key for `hold` (shift, ctrl, alt, a-z, 0-9, f1-f12) |
| `/dt kills` | kills in this zone, this session and lifetime |
| `/dt seals [on\|off]` | the seal timer in chat; `on\|off` shows or hides its line in the frame |
| `/dt reset session` | clear this session's counts; `/dt reset` moves the frame back |
| `/dt debug` | what the frame knows about your target |

Kills count when you, a party or alliance member, or one of your pets defeats the mob, or when your party had it claimed. Kills and drops are grouped by mob name and zone.

### Seal timer
The frame's last line is for farming seals, e.g. `Last seal 4m 12s ago, 9 kills since`, followed by:
- `none for 0:48` (gold): a seal dropped for your party less than 5 minutes ago, so no other can drop yet;
- `can drop` (green): the 5 minutes are up;
- `not from NMs` (red): you're targeting a notorious monster, which never drops seals.

Hover it for the seal, what it came from, and how many you've seen. On Phoenix, seals aren't in a mob's loot table (`mob_entity.cpp`):
- each kill has a 20% chance of one;
- after one drops, the killing party gets no other for 5 minutes;
- none come from NMs, from mobs too weak to give experience, or in battlefields and Dynamis;
- under level 50 a mob gives Beastmen's Seals, and from 50 a Beastmen's or a Kindred's Seal at even odds.

A seal counts when it enters your treasure pool. The time is real time, kept in your character's settings, so it carries on through a reload or a relog. If Phoenix has its seal-timer setting on, the 5 minutes also carry over zoning and your other characters. The addon only sees this character's seals, though.

## Where the numbers come from
The data in `data/` is generated from PhoenixXI's own server repository by `tools/gen_loot.py`: its era drop lists (with Phoenix's drop fixes and era removals applied), the server's drop roll, its treasure hunter table and caps, and the NPC sell prices. The script's header explains how the server rolls drops.

- Treasure hunter procs are disabled on PhoenixXI, so a mob's TH is the highest TH of anyone who acted on it (capped at 8 for a THF main, 4 otherwise).
- Beastmen's seals, crystals and other drops added by the server's code aren't in the loot tables; drops you get that aren't listed show under "Also seen" (and seals in the seal timer).
- The drop rate multiplier is Phoenix's default setting (1); the live server's own settings aren't public.

To regenerate the data from a Phoenix checkout:
```
python tools/gen_loot.py --phoenix C:\path\to\Phoenix
```
