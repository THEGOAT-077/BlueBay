<p align="center"><img src="assets/logo.svg" alt="BlueBay" width="420"></p>

<p align="center"><b>Accessible parking, checked by people.</b><br>
A community app that shows whether disabled parking bays near you are free right now.</p>

---

**Microburbs Hackathon, 7 November 2026 · Team BlueBay** · Task 2 track: facts about a place and what's nearby, delivered where you need them.

- 📊 **[report.html](report.html)**: data, method, results and held-out checks
- 🎬 **pitch.mp4** (45 seconds) and **demo.mp4** (up to 3 minutes)

## Who it helps

Drivers with a disability parking permit, their carers, and councils. Drivers find a free accessible bay without circling. Councils see which suburbs need more bays.

## The problem

Drivers with a disability parking permit often reach an accessible bay only to find it taken, then circle the block looking for another one. Maps can show *where* accessible bays are, but nothing tells you whether one is **free right now**.

## The idea

BlueBay lets the community keep accessible bays up to date in real time. People near a bay tick whether it's **free** or **taken**. Drivers **capture** a bay when they park and **release** it when they leave, and anyone looking for a park gets **directions to the nearest free bay**.

## Features

- **Live map of accessible bays.** Over 2,200 bays in Greater Sydney, loaded from OpenStreetMap, on Google Maps. Green is free, red is taken, grey is unsure, and blue is your own spot.
- **Capture and release.** Claim a bay when you park, so everyone else sees it as taken. Release it when you leave, and it shows as free straight away.
- **Free / Taken ticks.** Anyone near a bay can confirm its status. Reports older than 20 minutes fade back to "unsure".
- **"Still free?" popup.** Tapping a nearby bay asks you to confirm its status in one tap.
- **Directions to the nearest free bay**, with a drawn route, turn-by-turn steps and a hand-off to Google Maps.
- **Live updates.** Every change appears for everyone within about a second.
- **You have to be there.** Capturing, reporting and adding a bay all check your GPS position (100–150 m), in the app *and* in the database, so nobody can fake a report from home.
- **Accounts.** Start instantly as a guest, then sign in with an email link. Google sign-in is coded and will be switched on after the hackathon. The guest account is upgraded in place, so nothing is lost.
- **Votes and trust.** Signed-in users upvote or downvote pins ("is this a real bay, in the right place?") and people ("are their reports accurate?").
- **Badges.** People earn points for bays they add that the community upvotes, progressing from **Blue** to **Bronze** (10), **Silver** (20), **Gold** (30) and **Platinum** (50).
- **Mobile first**, with light and dark mode.

## Microburbs data and the clever step

Tap any bay in the City of Sydney and BlueBay shows **About this area**, using live Microburbs data: how hilly the streets are, the share of residents aged 55+, health places nearby, the nearest hospital, and the suburb's rank for missing bays.

**Where are bays missing?** ranks all 29 City of Sydney suburbs by an **accessible-parking gap score**:

1. Place every mapped bay in a suburb with point-in-polygon, using Microburbs suburb boundaries.
2. **Demand** = the average percentile rank of residents aged 55+, health places, and all destinations (Microburbs demographics and POIs).
3. **Hill factor** = 1 + the share of homes on steep ground (Microburbs slope). On a steep street, a bay 200 m away might as well not exist for a wheelchair user.
4. **Gap** = demand × hill ÷ (mapped bays + 1).

**Finding:** Surry Hills, Glebe, Darlinghurst, Potts Point and Ultimo have high need and **no mapped accessible bays**, while Moore Park (9 residents) has 14. A held-out check shows need does **not** predict where bays are mapped (leave-one-out error 2.29 bays vs a 2.16 baseline, rank correlation 0.11). The top 5 stays the same when any one demand signal is left out. Full details are in [report.html](report.html).

The ranking runs live against BlueBay's own database, so it improves as people add bays and earn badges for them.

## How it's built

| Part | Technology |
|---|---|
| App | A single `index.html`: plain HTML, CSS and JavaScript, no build step |
| Map, markers and directions | Google Maps JavaScript API (Advanced Markers, Routes) |
| Bay locations | OpenStreetMap via the Overpass API |
| Database, accounts and live updates | Supabase (Postgres, Auth, Realtime) |
| Suburb facts and the gap score | Microburbs Hackathon API, called from a Supabase Edge Function so the key stays secret |

All the rules live in the database, not just the app. Row-level security, column grants and triggers mean people can only act as themselves, can't vote on their own pins or themselves, can't fake timestamps, and can't capture or report from far away.

```
index.html                 the whole app
report.html                data, method, results and held-out checks
assets/logo.svg            logo
supabase/
  1-bays-reports-captures.sql   bays, Free/Taken reports, captures, live status view
  2-accounts-and-votes.sql      profiles, pin votes, user votes, trust scores
  3-signed-in-voting.sql        only signed-in users can vote
  4-badges.sql                  points and badges; sign-in needed to add a bay
  5-gps-check.sql               distance checks for capture, report and add
  6-sydney-bays-data.sql        2,204 accessible bays in Greater Sydney (OpenStreetMap)
  functions/microburbs/index.ts Edge Function: Microburbs area facts + gap score
```

## Run it yourself

1. **Supabase:** create a project, then run the files in `supabase/` in order in the SQL Editor. Under Authentication, turn on **anonymous sign-ins** and **manual linking**, and add your site's address to **Redirect URLs**.
2. **Google Maps:** create an API key with the **Maps JavaScript API** and **Routes API** enabled, restricted to your site's address.
3. **Microburbs:** in Supabase **Edge Functions**, deploy `supabase/functions/microburbs/index.ts` and add the secret `MICROBURBS_API_KEY` with your team key. The key never goes in the code. If your function's slug isn't `Microburbs`, change the `functions.invoke('Microburbs', …)` calls in `index.html`.
4. **Config:** put your Supabase project URL, publishable key and Google Maps key in `CONFIG` at the top of the script in `index.html`.
5. **Serve it** from any static host (GitHub Pages works), or locally with `python3 -m http.server`. Location and sign-in links need `https` or `localhost`.

The Supabase publishable key and the Google Maps browser key are meant to be public. The database rules protect the data, and the Maps key is locked to the site's address.

## What's next

- Native iOS and Android apps, with background location to suggest releasing a bay automatically when you drive off
- Time limits on captures, so forgotten ones expire
- Reporting blocked or misused bays
- Council and car-park operator data feeds, and expanding beyond Sydney
- Custom email sender and stronger anti-spoofing checks

## Credits

Suburb data from the **Microburbs Hackathon API**, data © Microburbs, estimates are indicative. No Microburbs output is stored in this repository. Bay locations © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors, available under the Open Database License. Map data © Google.
