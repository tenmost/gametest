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
- During a match the HUD name tags (`.label.p` / `.label.c`, set by `setHud()`) show the player's avatar + player name, not the character's name. Vs computer the opponent is "🤖 COMPUTER"; online the opponent's name and avatar come from presence (`name`, `av`). Status texts use `oppName()`.
- Tall stylized toy-figure characters with normal proportions (not chibi).
- Match = best of three fights, each fight has three health segments; 10-second pick timer, random card if time runs out.
- Crystals: blue (💎, spendable) and pink (future rewards). Signed-in players: blue crystals, wins/losses and unlocked arenas live in `sd_player_profiles` (server). Guests: no crystals at all (the old local test balance `sd_demo_progress_v1` is no longer used). Reward codes are redeemed only inside the profile window (signed in) via `sd_redeem_code(code)`: the server compares SHA-256(upper(code)) with `sd_reward_codes` (only hashes stored, `active` flag) and allows each account one redemption per code (`sd_code_redemptions`).
- Account menu (☰): guests see LOG IN + REGISTER + PLAY AS GUEST; signed-in players see PROFILE + LOG OUT.
- Guests get no rewards: no crystals, only the free arena (Orbital Temple), no name entry (they appear as "Guest123"). Crystals, unlocks, player name, avatar and friends need an account.

## Arenas (performance rules)
- Arenas are built in code (`temple` + `alternate.{city,ice,lava,jungle,factory}`), then `bakeStatic()` merges all static scenery into a few meshes per arena (one per material type, colours become vertex colours). This cut draw calls ~5–10× (e.g. graveyard ~1270 → ~210 per 2 frames).
- What gets baked: opaque Standard/Basic meshes that are direct children of the arena group, or inside a group with `userData.staticDecor=true`. Anything that moves or changes material at runtime (animals, flames, hands, mist, particles) must be in its own sub-Group or have `userData.dynamic=true` on the mesh or its material — otherwise it will be frozen into the baked mesh.
- New scenery must be added before the bake call (just above `fightArena.visible=false;scene.add(fightArena)`).
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
