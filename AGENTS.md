# Working on CaptureDesktop

CaptureDesktop is a macOS screen recorder (Swift, in `CaptureDesktop/`) with a marketing website (Astro, in `website/`) served at https://capturedesk.top. This file tells coding agents how to keep the two in step.

## The rule

**The app, the README and the website must describe the same product.** Any change that a user could notice is not finished until all three agree:

| When you change… | Also update… |
| --- | --- |
| A feature (added, removed, renamed, or its behaviour or defaults changed) | `website/src/data/features.ts` and the Features list in `README.md` |
| Output files or their contents | `website/src/data/outputs.ts` and the Output table in `README.md` |
| Command-line options | The options table in `README.md` |
| Requirements (macOS version, tools, DaVinci Resolve needs) | `README.md` and the build section of `website/src/pages/index.astro` |
| A known limit (added or fixed) | `website/src/data/outputs.ts` (known limits) and `README.md` |
| The look of a window shown on the site | The matching screenshot in `website/src/assets/screenshots/` |
| The app icon | `website/src/assets/brand/` and the icons in `website/public/` |

If a change has no user-visible effect, say so in your summary instead of touching the site.

## Where site content lives

- `website/src/data/features.ts` is the **single source of truth for the feature list**. The page renders it; do not write features directly into the page.
- `website/src/data/outputs.ts` holds the output-files table and the known limits.
- `website/src/pages/index.astro` holds the remaining copy (hero, how it works, build instructions).

## Accuracy

- Only claim what the code does. Check the source before writing a number (frame rates, formats, presets, track layout).
- The download button is automatic: the site looks up the latest GitHub release while it builds and shows the button and version only when a release with `CaptureDesktop.zip` exists. Do not hard-code a version or a download link. No testimonials, user counts, pricing or third-party logos.
- The DaVinci Resolve handoff needs Resolve **Studio**; say so wherever the handoff is mentioned. Keep the "not affiliated with Blackmagic Design" line in the footer.

## Screenshots

Screenshots on the site are real captures of the app's windows with placeholder content composited into the previews.

- Capture a single window (for example `screencapture -l <window id> -o`), never the full screen.
- Never publish anyone's real desktop, camera picture, window titles, file names or account details. Replace the screen preview, camera preview and review player with neutral placeholder images, masked to the rounded preview area.
- Keep the file names: `recorder.png`, `menu.png`, `review.png`, `hud.png`. Capture at 2x.
- Look at every final image at full size before it goes in.

## Website rules

- Astro, static output. **No React and no other client framework** (no Vue, Svelte, Preact or Solid integrations). Plain `.astro` components and plain CSS; a few lines of vanilla JavaScript at most.
- Icons come from [Tabler Icons](https://tabler.io/icons) (MIT) through `website/src/components/Icon.astro`, which inlines the SVG at build time: `<Icon name="brand-github" />`. Use that component rather than adding another icon set, an icon font or hand-drawn SVG. Each feature group's icon is the `icon` field in `features.ts`.
- No personal names, email addresses or local file paths in the site, the README or this file.
- Run it with Docker on port 4380:

  ```sh
  cd website
  docker compose up --build -d   # http://localhost:4380
  ```

  For quick iteration without Docker: `npm install && npm run dev`.
- After changing the site, rebuild and load the page to confirm it renders and that images and links work.

## Releases and publishing

Two GitHub Actions workflows run on a self-hosted Mac labelled `capturedesktop`, on pushes to `main` only:

- `.github/workflows/release.yml` runs `scripts/release.sh` when app code changes (`CaptureDesktop/`, `Config/`, `project.yml`). It builds a universal Release build, signs it with Developer ID, notarizes and staples it, and publishes a GitHub release with the asset `CaptureDesktop.zip`. No release is published unless notarization succeeds.
- `.github/workflows/site.yml` runs `scripts/deploy-site.sh` when `website/` changes. It builds the site and publishes it with rsync.

Rules:

- **Never add a `pull_request` trigger, or any trigger a fork can fire, to a workflow that uses the self-hosted runner.** That machine holds the signing key and the deploy key. Keep `permissions` minimal and identifiers (team ID, hosts, paths, keys) in repository secrets, not in YAML.
- Keep the logic in the two scripts and the YAML thin, so the scripts can be run by hand (`DRY_RUN=1` builds without notarizing, publishing or deploying).
- The release asset name `CaptureDesktop.zip` is fixed: the website links to `releases/latest/download/CaptureDesktop.zip`. Do not rename it without updating the site.
- Versions are `major.minor` from `MARKETING_VERSION` in `project.yml` plus the commit count as the patch number. To start a new minor or major version, edit `MARKETING_VERSION`.

## App notes

- Generate the Xcode project with `xcodegen generate` after adding or removing source files; the project file is not committed. Build commands are in `README.md`.
- `website/` must stay outside `CaptureDesktop/`, which XcodeGen treats as app sources.
- `Config/Local.xcconfig` holds a developer's signing identity and is gitignored. Never commit it.
