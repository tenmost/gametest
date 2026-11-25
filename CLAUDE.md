# Space Duel — project guide for Claude

Two brothers build this game together: Dainis (owner) and his brother (GitHub: kalninskaspars11-spec). Both use Claude.
Answer them in Latvian unless they write in another language.

## What the game is
Space Duel is a 3D space-themed rock-paper-scissors browser game.
- Live: https://tenmost.github.io/gametest/ (GitHub Pages, deploys from `main` about a minute after a push)
- Three.js 0.170 from jsDelivr, no build step, no npm. Everything runs as plain HTML + JS.
- Goal: earn money with it later, so every asset and library must be licensed for commercial use.

## Files
- `index.html` — the whole game (CSS + several `<script>` blocks). Large and dense; edit with small, targeted changes.
- `admin.html` — admin panel: upload/remove characters, view stats. Admins only (checked server-side).
- `astronaut-test.html` — older experiment page, not linked from the game.
- `assets/*.glb` — built-in character models (Meshy, rigged/animated). Other characters are uploaded through the admin panel to Supabase storage (`sd-models` bucket).
- `supabase/player_profiles.sql` — player accounts migration (applied as `sd_player_profiles`): profiles, server-verified matches vs computer, arena unlocks.
- `tools/optimize_glb.py` — shrink a new Meshy/Mixamo GLB (mesh, textures, keep chosen animations).
- `tools/reduce_keyframes.py` — drop redundant animation keyframes; run with `--verify` to see the max motion error.

## Design decisions (keep these unless the brothers change them)
- Moves are shown as cards (rock/paper/scissors), not finger gestures. Keep the 3D character models.
- No hand/arm pumping before the reveal; each character does a show-off move (dance, karate, etc.).
- Characters "talk" with text speech bubbles only — no voices.
- Announcer ("ROUND 1 – FIGHT!", "MATCH POINT", fight won/lost, victory/defeat) = big on-screen text + heavy Web Audio sounds (booms, gong, brass chords) + a deep male announcer voice via browser text-to-speech (`announceVoice`, pitch 0.1). The brothers chose this; characters themselves still have no voice. No audio files yet — a recorded, commercially licensed announcer voice may replace the TTS later.
- During a match the HUD shows a big square avatar in each top corner (`.hudAv`, size `--avs`) with the player name + a shorter health bar beside it (`.label`, `.hearts`), not the character's name. Hover/tap the avatar → `.hudTip` with stats (`fillHudTip`: wins, losses, matches, win %, streak, best; vs computer = matches won against you; online opponent stats come from presence fields `w,l,st,bs`). The old `.score` line is hidden. `setHud(p,c)` takes `{av, k (avatar key, 'cpu' for computer), name, st}`. Vs computer the opponent is "🤖 COMPUTER"; online the opponent's name and avatar come from presence (`name`, `av`). Status texts use `oppName()`.
- Tall stylized toy-figure characters with normal proportions (not chibi).
- Match = best of three fights, each fight has three health segments; 10-second pick timer (Neon City: 6 seconds, `pickTime()`), random card if time runs out.
- Crystals: blue (💎, spendable) and pink (future rewards). Signed-in players: blue crystals, wins/losses and unlocked arenas live in `sd_player_profiles` (server). Guests: no crystals at all (the old local test balance `sd_demo_progress_v1` is no longer used). Reward codes are redeemed only inside the profile window (signed in) via `sd_redeem_code(code)`: the server compares SHA-256(upper(code)) with `sd_reward_codes` (only hashes stored, `active` flag) and allows each account one redemption per code (`sd_code_redemptions`).
- EXIT MATCH button (`#matchExit`) shows only on the START ROUND screen (`#stage.waiting-fight-ready`). It warns first; leaving = lost match, no rewards. Signed in vs computer it calls `sd_match_forfeit` (loss, 0 crystals, losses +1, streak reset) — see `supabase/match_forfeit.sql`.
- Player name: free when the profile is created; changing it later costs 150 blue crystals (`NAME_PRICE` in index.html + `sd_set_username` in `supabase/username_price.sql`, keep in sync). Register/setup forms warn about it; rename needs a second CONFIRM click.
- Crystal counters: instant hover tooltip (`data-tip`, "saved to your profile" / "log in to earn") and a click opens `#gemInfo`: how to earn blue crystals, what they unlock (arenas, name change, characters coming soon); pink = coming soon (real money / rare events).
- Profile stat tiles (`.acStat`) have hover/tap tooltips (`data-tip`, texts in `TIPS` in the crystal-info script); the crystals tile opens `#gemInfo`.
- Avatars: 16 free + 15 premium bought with blue crystals (cheap 25: moon, satellite, octopus, ghost · rare 100: unicorn, shark, ninja, vampire · epic 300, glowing: flame, bolt, galaxy, crystal_ball · legendary 750, glowing + moving: vortex, crown, dragon_king). `AV` / `AV_PRICE` in index.html must match `sd_avatar_price()` in `supabase/premium_avatars.sql` (`unlocked_avatars` column, `sd_unlock_avatar`, `sd_set_avatar` checks ownership). Premium avatars are original drawn pictures in `assets/avatars/<key>.svg` (made for this game, free to use commercially; same cartoon style: dark outline, gradients, own background); legendary ones (vortex, crown, dragon_king) animate inside the SVG (SMIL). `avatarFill()` (`window.sdAvatarFill`) shows the picture for premium keys and the emoji for free ones; glow = CSS on `[data-tier]` / `[data-av]`. Premium avatars stay hidden if the `unlocked_avatars` column is missing. Clicking a locked one opens `#avBuyDialog` (`avBuy()`: preview, tier, price, balance, Unlock or "How to earn").
- No blinking text cursor / text selection anywhere except text fields (`caret-color:transparent` + `user-select:none` on html/body/dialogs) — it showed up when clicking the game with the browser's caret browsing on.
- Account menu (☰): guests see LOG IN + REGISTER + PLAY AS GUEST; signed-in players see PROFILE + LOG OUT.
- Guests get no rewards: no crystals, only the free arena (Orbital Temple), no name entry (they appear as "Guest123"). Crystals, unlocks, player name, avatar and friends need an account.

## Arenas (performance rules)
- Arenas are built in code (`temple` + `alternate.{city,ice,lava,jungle,factory}`), then `bakeStatic()` merges all static scenery into a few meshes per arena (one per material type, colours become vertex colours). This cut draw calls ~5–10× (e.g. graveyard ~1270 → ~210 per 2 frames).
- What gets baked: opaque Standard/Basic meshes that are direct children of the arena group, or inside a group with `userData.staticDecor=true`. Anything that moves or changes material at runtime (animals, flames, hands, mist, particles) must be in its own sub-Group or have `userData.dynamic=true` on the mesh or its material — otherwise it will be frozen into the baked mesh.
- New scenery must be added before the bake call (just above `fightArena.visible=false;scene.add(fightArena)`).
- Arena rules: Neon City = 6-second pick timer. Rejected by the brothers (don't add): frozen/unavailable cards, hiding the opponent's previous cards, character abilities. Lava wave (bigger damage) is still being discussed — it would need the server (`sd_match_play`) to know the arena.
- Arenas react to match events (`Scene3D.arenaHit(who,big)` from `runRound` on every lost health segment, bigger when a fight ends; `Scene3D.setFinal(on)` = red pulsing light + dimmed arena in the final round). Code: `updateArenaFX` — lava flares + embers, ice flash + penguins hop + bear rears, city neon flickers, jungle bird flies off, graveyard hand grabs + owls look. Only lights, particles and non-baked sub-groups are touched.
- Ambient particles (`PARTS`, `updateParticles`): snow in Frozen Temple, embers in Volcanic Cavern — one `Points` draw call each.

## Supabase
- Project URL and the publishable key are in `index.html` / `admin.html` (the publishable key is public by design).
- NEVER put a `service_role` key, database password or any secret in the repo, a chat or a screenshot.
- Game tables use the `sd_` prefix: `sd_characters`, `sd_rounds`, `sd_matches`, `sd_admins`; admin RPCs `sd_is_admin`, `sd_is_owner`, `sd_admin_*`, `sd_stats`.
- The game runs on the shared Supabase project `mrrqfrmgblbgrvkbrwvt` ("tenmost's Project"), which it shares with Dainis's site tenmost.com. The separate "Space Duel" project (`urfdxhnkyytcypexrogo`) was deleted in Nov 2026.
- In that project, only touch the game's own objects: `sd_*` tables and functions and the `sd-models` storage bucket. Never change or delete any other table, function, policy, bucket or setting — they belong to tenmost.com.
- Admins are listed in `sd_admins` (email only). The owner is decided by tenmost.com's `user_roles` table via `has_role(..., 'admin')` inside `sd_is_owner()` — read it, never change it. Only the owner can add/remove admins and set their passwords.
- Player accounts: Supabase Auth (email + password, shared with tenmost.com's auth) + `sd_player_profiles` (unique player name, avatar, crystals, wins, losses, unlocked arenas/characters). Profile window (`#accountDialog`): log in / register tabs, then avatar picker (emoji avatars; keys must match the check list in the DB and `AV` in index.html), name change (`sd_set_avatar`, `sd_set_username`), stats. Password: change in the profile (`auth.updateUser`); "Forgot password?" sends `resetPasswordForEmail` with `redirectTo` = the game URL, and the `PASSWORD_RECOVERY` auth event opens the "new password" view. The game URL must be in Supabase Auth → Redirect URLs (a tenmost.com setting — only Dainis changes it); otherwise the reset link goes to tenmost.com's Site URL. Clients can only SELECT their own row; every change goes through security-definer RPCs.
- Matches vs computer for signed-in players are server-verified: `sd_match_start()` creates a row in `sd_cpu_matches`, `sd_match_play(match, move)` picks the computer's card on the server, tracks health/fights and, when the match ends, adds crystals (win 8 perfect / 5, loss 1) and wins/losses. Min. 1 s between rounds. The client just plays the animation with the card the server returned.
- Win streaks: `current_streak` / `best_streak` in `sd_player_profiles`, updated by the trigger `sd_cpu_matches_streak` when a match vs computer ends (online matches don't count yet). Profile shows wins, losses, matches, win %, streak, best streak.
- Friends (`supabase/friends_and_streaks.sql`): table `sd_friends` (requester, addressee, pending/accepted), no direct client access — RPCs `sd_friend_request(username)` (auto-accepts if they already asked you), `sd_friend_respond(id, accept)`, `sd_friend_remove(id)`, `sd_friends_list()` (friends' stats only once accepted). UI is the FRIENDS section in `#accountDialog`; incoming requests show 🔔 next to the player name.
- Arena unlocks: `sd_unlock_map(map)` checks price + balance on the server (prices: city 20, jungle 35, ice 50, lava 75, factory 100 — keep them in sync with `prices` in index.html).
- Daily missions (`supabase/daily_missions.sql`): 3 per day from a pool of 6, reset 00:00 UTC; progress computed on the server from `sd_cpu_matches` (forfeits don't count); `sd_daily_missions()`, `sd_daily_claim(mission)` → crystals. UI: 📋 DAILY button in `#accountBar` + `#dailyDialog`; hidden if the server functions are missing.
- Online matches do not give crystals yet (no trusted verifier for two-browser matches).
- Rewards (crystals, unlocks) must never be granted by a browser call that trusts the client. Spending must be checked server-side (price + balance).

## Online multiplayer
- Supabase Realtime channel `spaceduel-<ROOM>`; presence for the lobby, broadcast for game events.
- Moves use commit-reveal: `pick` sends only a SHA-256 hash (round:move:salt); `reveal` sends move + salt after both players have committed. Do not send the plain move in `pick` — that lets the opponent read it before choosing.
- Both players must run the same version; after changing the protocol, both reload.

## Working together
- Always `git pull` before starting and push small commits with clear messages, so the two brothers' changes don't collide.
- Agree who is working on what; avoid both editing the same part of `index.html` at the same time.
- After a change, check the browser console for errors and, for online changes, test with two tabs (`?room=TESTCODE` in both).
