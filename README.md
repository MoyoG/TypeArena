# TypeArena — GitHub classroom typing competition

Students sign in with their GitHub accounts and join a teacher-created race with a six-character code. Each race supports up to 40 signed-in students, with live participant updates and a ranked WPM/accuracy result board.

A browser-based, mobile-friendly classroom typing tutor with GitHub OAuth, individual practice, teacher-only races, live result updates, server-controlled score submission, and one bonus point for each finalized race winner.

## Stack
- React + Vite frontend
- Supabase Auth (GitHub OAuth), Postgres, RPC and Realtime
- Vercel for hosting, GitHub for source code and automatic deploys

## Setup (no local computer required)

1. Create a **Supabase** project at https://supabase.com/dashboard. Open **SQL Editor** and run the full contents of `supabase/schema.sql`.
2. In **GitHub → Settings → Developer settings → OAuth Apps → New OAuth App**, create a GitHub OAuth application. Set Homepage URL to your eventual Vercel site; set **Authorization callback URL** to `https://YOUR_SUPABASE_PROJECT.supabase.co/auth/v1/callback` (NOT the Vercel site). Copy Client ID and Client Secret.
3. In **Supabase → Authentication → Providers → GitHub**, enable GitHub and paste Client ID and Client Secret. Do not put the GitHub client secret in Vite environment variables or GitHub source.
4. In **Supabase → Authentication → URL Configuration**, set Site URL to your eventual Vercel domain and add `https://YOUR_VERCEL_DOMAIN/**` under redirect URLs. For local development also add `http://localhost:5173/**`.
5. Create a GitHub repository and upload this project preserving its folders. Connect it in https://vercel.com/new. Framework: **Vite**; build command: `npm run build`; output: `dist`. Add environment variables `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` (Supabase **Project Settings → API**, use publishable/anon key, NEVER service_role). Deploy.
6. Visit the deployed app and **sign in once with your own GitHub account**. Then in Supabase SQL Editor, promote **only your exact username**:
   ```sql
   update public.profiles set is_teacher=true where username='YOUR_EXACT_GITHUB_USERNAME';
   ```
   Reload the app. The **Teacher** tab will appear. Do not promote students.
7. If you used a placeholder Vercel URL in GitHub OAuth or Supabase Auth settings, update them to the actual deployed domain. Students sign in with GitHub and can join races with a 6-character code.

## Teacher workflow
1. Open Teacher → create a race (passage length 40–500 characters).
2. Share the join code. Students sign in and join while race is waiting.
3. Start the race; there is a five-second countdown, then a 90-second race window.
4. After the 90 seconds expire, click **Finalize results & bonus**. The top eligible finisher receives +1 point (minimum 90% accuracy; full passage required). Repeated finalization cannot award multiple points.
5. View accumulated bonus points in Leaderboard. Practice results never count toward bonus points.

## Security and fairness notes
- Supabase row-level security restricts practice history to its owner; all mutation operations are guarded by PostgreSQL functions with server-side teacher checks.
- Scores are calculated server-side using the stored passage, authenticated participant, time window, and server-clock bounds. Paste is blocked in the browser. These are deterrents, **not cheating-proof**: determined users can forge browser/API events. For grades or consequential prizes, supervise the race and review unusual scores.
- Race submissions require the **exact full passage**. The winner is determined by WPM, then accuracy, then elapsed time and submission time. There is no bonus if nobody submits a valid result.
- Race results and participant names are visible to signed-in users of this Supabase project. Use a separate Supabase project per class if needed. Only invite authorized students; GitHub login by itself does not enforce class membership.
- The app intentionally does not change any university gradebook. It records bonus points inside TypeArena only. Export or transfer points manually after review.

## Local development
```bash
cp .env.example .env
npm install
npm run dev
```

## Deployment troubleshooting
- Blank setup screen: check Vercel environment variables and redeploy.
- GitHub login error: confirm callback URL is the **Supabase** callback URL, and Site URL / redirect allowlist match Vercel.
- No Teacher tab: sign in first, run the promotion SQL for the exact GitHub username, reload.
- Races not updating: check Realtime publication in SQL; the race screen also polls every 4 seconds.
- Race not finalizing: wait for the full 90-second window to expire.

## Limits
This is a deployable source project, not an already-hosted website. Requires you to connect your own GitHub, Supabase, and Vercel accounts. No GitHub OAuth credentials or production database are bundled.

## Typing tests update

20 built-in tests grouped into words, words + numbers, punctuation, and symbols. Choose 1- or 3-minute tests from the practice toolbar. The custom passage editor accepts pasted text (20–12,000 characters); pasting into the typing response is blocked. The default passages repeat to support full timed sessions.
