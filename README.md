# Soul Link for the Pokémon DS and 3DS games

Play Soul Link Nuzlocke with friends: you see each other walking around
as real in-game characters, and the Soul Link panel tracks everyone's encounters,
links and deaths. This program is not perfect expect bugs and or glitches. Works with:

| Region | Games |
|---|---|
| Unova | Black, White |
| Unova | Black 2, White 2 |
| Sinnoh | Diamond, Pearl, Platinum |
| Johto | HeartGold, SoulSilver |

You need [BizHawk](https://github.com/TASEmulators/BizHawk) (Soul Link can download it for you) and
your own copy of the game. No game files come with Soul Link.

## Download

Press the green **Code** button > **Download ZIP**, and unzip it anywhere (not in *Program Files*).
Or press **Share Soul Link with a friend** in your own copy to make a zip for a friend.

## Quick start

1. **Double-click `Soul Link`** (`Soul Link.exe`, with the Poké Ball icon). The Soul Link window opens.
2. **Pick your game file**: your own dump of one of those games (`.nds`, or the `.zip` it came in).
   Games from the same row of the table can be mixed (say Diamond with Platinum), and so can boy
   and girl characters. **Games from different rows can't be mixed**: their areas don't match, so
   encounters can't be linked. A friend whose game is from another row can't join (Soul Link tells
   them which games the lobby plays).
3. **Pick BizHawk** (`EmuHawk.exe`), or press **Get BizHawk** to download it automatically.
4. Type **your name** (what the others see in the lobby), then one of:
   - **Host a game**: this opens a **lobby** and gives you a **join code** (like `6B01R-JVENR-K3M9QX`).
     Press **Copy code** and send it to your friends. You see everyone who joins. When everyone
     is in, press **Start the game for everyone**: every player's game starts at once.
   - **Join**: paste a friend's join code and press **Join**. You're in their lobby (your game
     doesn't start yet). It starts when the host starts it, or press **Start my game**.
   - **Try it alone**: no friend needed. A *Test Buddy* follows you around so you can see how it works.

To stop playing together, press **Close the lobby** / **Leave the lobby** (a running game keeps
running). The link also ends by itself once both the Soul Link window and your game are closed,
and the router port Soul Link opened is closed again.

BizHawk opens with the game, and the **Soul Link** panel shows next to it.
Your settings are remembered, so next time it's just one click.

## Randomized runs

- **Host:** tick **Randomized run**, then press **Host a game**. Soul Link finds your randomizer
  settings (`.rnqs`) by itself, or press **Settings...** to pick them. Don't have any yet? Press
  Cancel in that dialog: the randomizer opens, so load your game there, pick your options and
  use *Save Settings*. Soul Link downloads the
  [Universal Pokémon Randomizer ZX](https://github.com/Ajarmar/universal-pokemon-randomizer-zx)
  for you if needed. It needs Java: [adoptium.net](https://adoptium.net).
- **Friends:** nothing extra. Paste the join code and press **Join**. Their own game is
  randomized with the host's settings automatically before it starts.
- The randomized game is made once and **kept for the whole run**, so encounters and saves
  stay the same between sessions. **New randomized run** starts over: next time you host,
  everyone gets a newly randomized game, a fresh save and a fresh Nuzlocke.
- Untick **Randomized run** to play the normal game again.

## Sending Soul Link to friends

Press **Share Soul Link with a friend**: it puts `Soul Link.zip` on your Desktop. Send that
file; your friend unzips it, double-clicks `Soul Link`, and picks their own game file.
(If Windows says it protected the PC from a file from the internet, choose *More info* > *Run anyway*.)

## If friends can't connect

- When you host, Soul Link asks your router to open the port automatically. If the
  window says your router didn't, the easiest fix is **[Tailscale](https://tailscale.com)**:
  everyone installs it and joins the same network, and the host uses the **Tailscale** code.
- On the same Wi-Fi, use the **Same Wi-Fi / LAN** code.
- The room password is optional; if you set one, everyone has to type the same one.
- If Windows asks about the firewall the first time you host, press **Allow** for **Soul Link**.

## If your antivirus blocks Soul Link

Soul Link is one ordinary program, `Soul Link.exe`: no scripts, nothing hidden. It starts a second
copy of itself for the connection to the others (that one keeps going while your game runs), and
starts BizHawk. Its source code is in the `source` folder, so anyone can check what it does.

Some antivirus programs (for example Bitdefender's *Advanced Threat Defense*) judge programs by
what they do, and a new program that connects to other PCs can still look suspicious to them:

- If it gets blocked, restore it from the antivirus's quarantine and add `Soul Link.exe` as an
  exception (in Bitdefender: *Protection* > *Advanced Threat Defense*, then its exceptions).
- You can also report it to the antivirus maker as a false positive.

## Safety

- **Only people you send the join code to can get in.** Every lobby gets its own private room
  key, and it's built into the join code (the last 6 letters). Someone who finds your open port
  without the code can't join, and a wrong try makes them wait before trying again.
- Every message from another player is checked before it's used: only known kinds, from the
  player who sent it, with sensible values. A broken or hostile message is thrown away; it can't
  crash anyone's game or change another player's team.
- The host limits how many connections there can be and how fast each one may send.
- The router port is closed again when the lobby closes (or once both the Soul Link window and
  your game are closed).

## The Nuzlocke rules it tracks

- The run starts once you have Poké Balls.
- Your **first encounter in each area** counts. Pokémon you already have don't use up an
  area (dupes clause).
- Everyone's catches from the same area are **linked**. If one of them faints, the whole
  link is dead; if someone misses their encounter, that link can't be used.
- Linked Pokémon go in and out of the party together.
- The panel warns you when your party breaks a rule.

## Reading the panel

**Point at anything on the panel** (a Pokémon, a link, the badges, the level cap, an area) and a
short explanation pops up saying what it means.

The panel has three tabs (click to switch):

- **Team & Links**: a strip at the top with your next encounter and level cap (click it for
  the Routes tab), then everyone's team and the links. Each link has a **numbered coloured
  circle**; the same circle sits on that Pokémon in every player's team, so linked Pokémon are
  easy to spot (no circle = not part of a link). Each link is ALIVE, WAITING (someone hasn't
  caught theirs yet), MISSED or DEAD. Levels above the level cap turn orange. When a Pokémon
  evolves, its link shows the evolved form.
- **Routes**: every area with wild Pokémon in story order, with everyone's encounter there.
  On top: your **next encounter** (plus areas you skipped that are still open) and the
  **level cap**: the strongest Pokémon of the next gym leader or boss, read from your game
  (so it's right for randomized games too). Surf/fishing-only areas are marked.
- **Graveyard**: every Pokémon that died, whose it was, its level, where it was caught and
  where it died.

The panel fits your screen. Drag its edges to resize it: everything scales with it.

The Pokémon are shown with their battle sprites, moving like they do in battle, in shiny colours
(with a gold star) when they're shiny and with the female look for species where it differs.
Everyone needs this version for the shiny/female looks to come across. The sprites are read
from your own game the first time each Pokémon shows up (the small icon stands in for a few
seconds meanwhile) and kept in `runtime/cache`.

## Settings (optional)

`profiles/default.json` holds your settings. Extra options:

- `"players": "drawn"`: draw other players on top of the screen instead of as in-game characters.
- `"panel": "docked"`: show the Soul Link panel next to the game instead of in its own window.
- `"rules": { "typeRule": true, "dupes": false }`: switch rules on or off.
- `"sprite": "girl"` or `"boy"`: what the others see you as (normally taken from your save).
- `"showLuaConsole": true`: keep BizHawk's Lua Console window open (it's hidden by default;
  *Tools > Lua Console* in BizHawk shows it again anytime).

## Troubleshooting

- If something breaks, the game screen says so and the details are in `runtime/error.txt`.
- BizHawk needs Microsoft's **Visual C++ runtime (x64)**. If your PC doesn't have it, the BizHawk
  line in the Soul Link window says so, and **Get BizHawk** offers to download it from Microsoft.
- The connection log is in `runtime/<profile>/link.log`.

## Building it yourself

`Soul Link.exe` is built from the C# files in `source` with the compiler that comes with Windows
(.NET Framework 4, nothing to install): run `source\build.cmd`. The in-game part is the Lua in `lib`,
started through `SoulLink.lua`.

## Legal

Soul Link is a fan project, not affiliated with or endorsed by Nintendo, Game Freak, Creatures or
The Pokémon Company. Pokémon and the game names are their trademarks. Soul Link contains no game
files: it reads what it shows from your own copy of the game while you play. MIT licensed (see `LICENSE`).
