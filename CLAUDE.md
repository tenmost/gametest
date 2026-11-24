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
- `supabase/player_profiles.sql` — prepared migration for player accounts (not applied yet).
- `tools/optimize_glb.py` — shrink a new Meshy/Mixamo GLB (mesh, textures, keep chosen animations).
- `tools/reduce_keyframes.py` — drop redundant animation keyframes; run with `--verify` to see the max motion error.

## Design decisions (keep these unless the brothers change them)
- Moves are shown as cards (rock/paper/scissors), not finger gestures. Keep the 3D character models.
- No hand/arm pumping before the reveal; each character does a show-off move (dance, karate, etc.).
- Characters "talk" with text speech bubbles only — no voices.
- Tall stylized toy-figure characters with normal proportions (not chibi).
- Match = best of three fights, each fight has three health segments; 10-second pick timer, random card if time runs out.
- Crystals: blue (💎, spendable) and pink (future rewards). Currently local-only in the browser (`sd_demo_progress_v1`), not real progress yet.

## Supabase
- Project URL and the publishable key are in `index.html` / `admin.html` (the publishable key is public by design).
- NEVER put a `service_role` key, database password or any secret in the repo, a chat or a screenshot.
- Game tables use the `sd_` prefix: `sd_characters`, `sd_rounds`, `sd_matches`, `sd_admins`; admin RPCs `sd_is_admin`, `sd_is_owner`, `sd_admin_*`, `sd_stats`.
- The project is currently shared with Dainis's other site (tenmost.com). Do not touch tables without the `sd_` prefix. Moving the game to its own Supabase project is planned.
- Rewards (crystals, unlocks) must never be granted by a browser call that trusts the client. Spending must be checked server-side (price + balance).

## Online multiplayer
- Supabase Realtime channel `spaceduel-<ROOM>`; presence for the lobby, broadcast for game events.
- Moves use commit-reveal: `pick` sends only a SHA-256 hash (round:move:salt); `reveal` sends move + salt after both players have committed. Do not send the plain move in `pick` — that lets the opponent read it before choosing.
- Both players must run the same version; after changing the protocol, both reload.

## Working together
- Always `git pull` before starting and push small commits with clear messages, so the two brothers' changes don't collide.
- Agree who is working on what; avoid both editing the same part of `index.html` at the same time.
- After a change, check the browser console for errors and, for online changes, test with two tabs (`?room=TESTCODE` in both).
