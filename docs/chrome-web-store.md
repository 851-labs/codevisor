# Chrome Web Store listing

This doc covers what is needed to publish the Codevisor Chrome extension on the Chrome Web Store:
the policy audit, packaging, the extension ID plan, and a draft of every listing field. Linear:
851-2745.

## How the extension works today

- Source: `packages/automation/resources/browser-extension`. Plain Manifest V3 JavaScript with no
  build step.
- The extension opens a WebSocket to the Codevisor server on the same computer
  (`ws://127.0.0.1:49361/v1/browser-use/extension/socket`). The server only accepts the socket
  when its `Origin` is `chrome-extension://clemkifaacpllomplgomnkbeoiindbhl`
  (`apps/server/src/routes/events.ts`). Codevisor uses no native messaging and no
  `externally_connectable`.
- Install: when an agent first picks "Use Codevisor Extension", the composer asks the user to drag
  a zip into `chrome://extensions` (`browser-setup-broker.ts`). The server rebuilds that zip on
  every start from the bundled source, with the manifest `key` that pins the ID above
  (`prepareBrowserExtension` in `browser-extension-relay.ts`).
- Detection: the server looks for that ID in Chrome, Chromium, Brave and Edge profile folders
  (`browserExtensionInstallation`).
- Updates: there are none. A dragged-in copy stays at whatever version it was installed with. The
  bundled manifest is fixed at version `0.2.0`, so the app can't tell old copies from new ones.
- Production builds already link to `chromewebstore.google.com/detail/<id>` (`webStore` setup
  mode). The store item exists with that ID but is still a draft, so the link works only after
  the listing is published.

## Packaging and upload

The Stable release already builds the store zip, and a separate workflow uploads it.

| Step                 | What runs                                                                                                                                                                                                                   |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Build (every Stable) | `publish-stable.yml` runs `node scripts/release/build-browser-extension.mjs <version>` and attaches `Codevisor-Chrome-<version>.zip` and its `.sha256` to the GitHub release.                                               |
| Build locally        | `bun run release:browser-extension 0.1.107 dist/release`. The zip is byte-for-byte reproducible: the local build of v0.1.107 matches the release checksum.                                                                  |
| Upload and submit    | Actions, then **Publish Chrome Extension** (`publish-browser-extension.yml`), with the Stable version. It verifies the checksum, uploads through the Chrome Web Store API v2, waits for processing, and submits for review. |
| Hold after approval  | Tick `stage_only` to submit with `STAGED_PUBLISH`. The approved version then waits until someone clicks Publish in the dashboard. Use it to release the extension at the same moment as the app that expects it.            |
| Check status         | `node scripts/release/publish-browser-extension.mjs --status-only` with the three `CHROME_WEBSTORE_*` variables set.                                                                                                        |

The build sets `version` to the app version, keeps the name and summary, strips `key`, points the
relay at the production port, and checks the result. The build fails if:

- the manifest isn't Manifest V3,
- the name is over 75 characters or the summary is over 132,
- the manifest sets its own `content_security_policy`,
- a page or script loads remote script or calls `eval` or `new Function`, or
- the manifest asks for a permission or host permission that isn't in the reviewed list in
  `build-browser-extension.mjs`.

The last check matters most. When an update asks for a new permission, Chrome disables the
extension for every user until they accept it. To add one, justify it in
[Permission justifications](#permission-justifications) first, then add it to the list.

### Credentials

The workflow signs in to Google with GitHub OIDC (keyless). The `chrome-web-store-production`
GitHub environment already has these variables:

| Variable                         | Current value                                                                    | Notes                                                                                |
| -------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/48659336838/locations/global/workloadIdentityPools/github-actions/...` | Must trust this repository's OIDC tokens.                                            |
| `GCP_SERVICE_ACCOUNT`            | `codevisor-chrome-publisher@labs-851.iam.gserviceaccount.com`                    | Must be added as a user under the publisher in the developer dashboard.              |
| `CHROME_WEBSTORE_PUBLISHER_ID`   | `79f7ff5e-c4b0-4019-aa45-c0d99e58a805`                                           | From the developer dashboard's account page. Confirm it matches the account you use. |
| `CHROME_WEBSTORE_EXTENSION_ID`   | `clemkifaacpllomplgomnkbeoiindbhl`                                               | Correct. The store item has the same ID as the app.                                  |

The Chrome Web Store API must also be enabled in the `labs-851` Google Cloud project. None of this
has been tested end to end: the only run of the workflow, on 2026-07-24, was skipped.

## Policy audit

| Area                                                                  | Result                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Manifest V3                                                           | Passes. The background script is a service worker, the clipboard goes through an offscreen document, and reconnects use `chrome.alarms`. The build now enforces MV3.                                                                                                                                                                                                                                  |
| Host permissions                                                      | **Fixed.** `<all_urls>` was removed. `chrome.debugger` doesn't need host permissions, and the relay socket is on loopback, which Local Network Access doesn't gate for extensions. Verified on Chromium 151 with the manifest before and after: attach, evaluate, screenshot, click, cross-origin iframes, an HTTPS site, new tabs, downloads, history, tab groups and clipboard all behave the same. |
| API permissions                                                       | Every remaining permission is used. See [Permission justifications](#permission-justifications).                                                                                                                                                                                                                                                                                                      |
| Remote code                                                           | Passes. All extension JavaScript ships in the package, and no page loads remote script. No `eval` or `new Function`. The build now enforces this.                                                                                                                                                                                                                                                     |
| CSP                                                                   | Passes. Chrome's default extension CSP applies, and pages only load scripts from the package. The build rejects a custom CSP.                                                                                                                                                                                                                                                                         |
| Native messaging                                                      | Not used. The link to the app is a loopback WebSocket that the server checks by `Origin`.                                                                                                                                                                                                                                                                                                             |
| `externally_connectable`, content scripts, `web_accessible_resources` | None declared.                                                                                                                                                                                                                                                                                                                                                                                        |
| `key` in manifest                                                     | Stripped from the store zip. Only unpacked builds use it.                                                                                                                                                                                                                                                                                                                                             |
| Privacy policy                                                        | Already live at <https://www.codevisor.dev/privacy> (effective 2026-09-11). It covers the extension's data, says browser data isn't sold or used for ads, and includes the Limited Use statement. No new policy is needed.                                                                                                                                                                            |
| Reproducible packaging                                                | Passes. See above.                                                                                                                                                                                                                                                                                                                                                                                    |

### Review risks that can't be fixed in code

1. **`debugger` means in-depth review.** Expect a slower first review (days to a few weeks). Chrome
   also shows "Codevisor started debugging this browser" while it controls a tab. That is expected
   and the privacy policy mentions it. Similar store listings, like Playwright's MCP bridge, also
   relay DevTools Protocol commands.
2. **DevTools commands from the app can run script in pages.** The extension forwards DevTools
   Protocol commands from the Codevisor app on the same computer, including `Runtime.evaluate`.
   This isn't remote code under the policy: no code runs in the extension's own context, and
   nothing comes from a server. The `debugger` justification says it openly so a reviewer doesn't
   find it first.
3. **The reviewer can't test it on its own.** It does nothing without the Codevisor app running.
   Reviews often fail with "couldn't verify functionality". The test instructions and a short
   screen recording help most.
4. **`history` and `clipboardRead` are sensitive.** Both are used and justified below. Moving them
   to `optional_permissions` and asking on first use would make the install prompt shorter. That
   is a product decision for Phase 2, and the build guard covers optional permissions too.
5. **Store icon padding.** Chrome's guidelines ask for 96×96 artwork inside the 128×128 icon, with
   16 px of transparent padding. The packaged icons are cropped close to the edge, so the listing
   uses a separate padded store icon. See [Images](#images).
6. **`connect.html` isn't used.** It is packaged but never opened. It does no harm in review. It
   could become the page opened after install in Phase 2, and it already holds the data
   disclosure.

## Extension ID and key

**Where the ID is used.** `CODEVISOR_BROWSER_EXTENSION_ID` in `browser-extension-relay.ts` is used
in three places:

1. The server's WebSocket `Origin` check. Any other ID is refused.
2. Install detection in Chrome profile folders.
3. The Web Store link that production builds open.

Nothing else uses the ID: there is no native messaging host manifest and no
`externally_connectable`.

**The store item already has this ID.** The draft item, created on 2026-07-22, is
`clemkifaacpllomplgomnkbeoiindbhl`. Its public key on the Package tab ("View public key") is the
same key as `manifest.json` `key`. So the ID doesn't change:

- the app already accepts the store-installed extension, with no code change and no legacy ID;
- `CHROME_WEBSTORE_EXTENSION_ID` is already correct;
- the store zip still strips `key`, because the store item fixes the ID for every later upload.

A dragged-in copy and a store copy share the ID. This hasn't been tested yet: check what Chrome does
when a user with a dragged-in copy installs from the store, and tell them to remove the old copy if
needed.

## Listing draft

**Name:** Codevisor

**Summary** (the manifest `description`, 132 characters max). Current text: "Control Chrome with
Codevisor." Proposed, needs a decision because it also shows in `chrome://extensions`:

> Let your Codevisor agents use the Chrome tabs you choose, so they can test, debug and finish web
> tasks with your signed-in sessions.

**Category:** Developer Tools.

**Language:** English.

**Official URL:** codevisor.dev (verified in Search Console). **Homepage URL:**
<https://www.codevisor.dev>. **Support URL:** <https://www.codevisor.dev/support>.

**Description:**

> Codevisor runs AI coding agents, like Claude Code, Codex and others, on your Mac. This extension
> lets those agents work in the Chrome you already use, with your tabs, sign-ins and settings,
> instead of a separate browser.
>
> What it does
> • Connects Chrome to the Codevisor app on the same computer. It does nothing without Codevisor
> running.
> • Lets an agent open, inspect and control the tabs it needs for your task: read the page, click,
> type, take screenshots, and handle downloads.
> • Groups the tabs an agent is working in so you can see them at a glance.
> • Searches your Chrome history and uses the clipboard only when a task needs it.
> • Shows the connection status and the controlled tabs in the toolbar popup.
>
> You stay in control
> • Chrome shows its debugging banner whenever Codevisor controls a tab.
> • Turn Browser Use off in Codevisor, or remove the extension, at any time.
> • The extension only talks to Codevisor on your own computer. It has no servers of its own and
> no analytics.
>
> Page content an agent reads may be sent to the AI provider you picked in Codevisor, as part of
> your task. Codevisor never sells browser data or uses it for advertising. Privacy policy:
> https://www.codevisor.dev/privacy
>
> Requires the Codevisor app for macOS: https://www.codevisor.dev

**Single purpose:**

> Let the Codevisor desktop app's AI agents use the user's Chrome tabs to carry out the tasks the
> user gives them.

### Permission justifications

| Permission       | Justification                                                                                                                                                                                                                                                     |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `debugger`       | Attaches to tabs the user lets Codevisor use, so the agent can read the page, take screenshots, and click and type through the DevTools Protocol. Commands come only from the Codevisor app on the same computer, and can include evaluating script in that page. |
| `tabs`           | Lists open tabs with their titles and URLs so the user and agent can choose which tab to work in, and opens new tabs for a task.                                                                                                                                  |
| `tabGroups`      | Puts the tabs an agent is working in into a labeled group so the user can see them.                                                                                                                                                                               |
| `history`        | Searches Chrome history when the user or the agent asks to find a page visited before. Results go only to the Codevisor app.                                                                                                                                      |
| `downloads`      | Reports files the agent downloads during a task, with their name and progress, so the agent can use them.                                                                                                                                                         |
| `clipboardRead`  | Reads the clipboard when a task pastes content, for example pasting into a web form.                                                                                                                                                                              |
| `clipboardWrite` | Writes to the clipboard when a task copies content.                                                                                                                                                                                                               |
| `offscreen`      | Hosts the offscreen document Manifest V3 requires for clipboard access from a service worker.                                                                                                                                                                     |
| `alarms`         | Reconnects to the Codevisor app after it restarts, with backoff, without keeping the service worker alive.                                                                                                                                                        |
| Host permissions | None requested.                                                                                                                                                                                                                                                   |

**Remote code:** "No, I am not using remote code." All extension JavaScript is in the package. See
review risk 2.

### Data use (Privacy tab)

Collected, meaning the extension handles it and passes it to the Codevisor app on the same
computer:

- **Web history**: tab URLs and titles, and history search results.
- **Website content**: page text, images and structure of tabs the agent works in.
- **User activity**: clicks and typing that the agent performs, and page events in controlled
  tabs.

Not collected: personally identifiable information, health, financial and payment, authentication
information, personal communications, and location. Pages an agent reads can contain any of these,
but the extension doesn't look for or extract them. Declare a category too if a reviewer asks;
over-declaring is allowed.

Certify all three: data isn't sold or transferred outside the approved uses, isn't used for
unrelated purposes, and isn't used for creditworthiness or lending. Sending page content to the AI
provider the user chose is part of the user-facing feature.

**Privacy policy URL:** <https://www.codevisor.dev/privacy>

### Images

The uploaded images and their sources are in `docs/assets/chrome-web-store/`. Run `render.sh`
there to rebuild the PNGs from the HTML pages with headless Chrome.

| Asset              | File                                    | Notes                                                                                                     |
| ------------------ | --------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Store icon         | `store-icon.png` (128×128)              | `source/codevisor-icon.png` (from `apps/www/public`) scaled so the artwork is 96×96, with 16 px padding.  |
| Screenshot 1       | `screenshot-1.png` (1280×800, no alpha) | Chrome with the Codevisor tab group, the debugging banner and the popup showing "Connected to Codevisor". |
| Screenshot 2       | `screenshot-2.png` (1280×800, no alpha) | The Codevisor chat that drove that Chrome through the extension.                                          |
| Small promo tile   | `small-promo-tile.png` (440×280)        | Icon and wordmark on the site's black background.                                                         |
| Marquee promo tile | None                                    | Optional. Only needed if the store features the extension.                                                |
| Promo video        | None                                    | Optional. A YouTube link.                                                                                 |

The two captures in `source/` are real windows. Chrome ran with a temporary profile and the
unpacked extension (loaded with the CDP `Extensions.loadUnpacked` command), connected to the
Codevisor app on the same Mac. A Codevisor chat then asked to open codevisor.dev "using the
Codevisor Extension". The chat capture has its inspector and sidebar hidden, and some empty rows
removed above the composer.

### Test instructions (for the reviewer)

The dashboard allows 500 characters. This is the saved text:

> Needs the Codevisor app for macOS; the extension does nothing without it. The extension needs no
> account.
>
> 1. Install Codevisor from https://www.codevisor.dev and sign in to an AI provider.
> 2. Install this extension. Its popup shows "Connected to Codevisor".
> 3. In Codevisor, start a chat: "Open example.com in my Chrome and tell me the page title." If
>    asked which browser, pick "Use Codevisor Extension".
> 4. Chrome shows its debugging banner, the tab joins a Codevisor group, and the agent replies.

If reviewers need an AI provider account, give them test credentials in this tab.

## Dashboard status

As of 2026-10-20 the draft is ready to submit. "Why can't I submit?" is gone and "Submit for
review" is enabled. Nobody has pressed it yet.

| Area              | State                                                                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Publisher         | `79f7ff5e-c4b0-4019-aa45-c0d99e58a805`, display name Codevisor, owned by dylan@851.sh. Trader account, verified as 851 INC.           |
| Contact email     | dylan@851.sh, verified.                                                                                                               |
| Service account   | `codevisor-chrome-publisher@labs-851.iam.gserviceaccount.com` is added to the publisher.                                              |
| Package           | 0.1.108, built from main with `bun run release:browser-extension 0.1.108`. Permissions match the reviewed list; no host permissions.  |
| Store listing     | The description, category, language and URLs above, the padded icon, two screenshots and the small promo tile.                        |
| Privacy           | Single purpose, all nine justifications, remote code "No", the three data types, the three certifications and the privacy policy URL. |
| Distribution      | Free, public.                                                                                                                         |
| Test instructions | The text above.                                                                                                                       |

The draft package is 0.1.108, the next Stable version. If the dashboard refuses a later upload of
the same version, publish with the following Stable.

Still open:

- [ ] **Submit.** Press "Submit for review" in the dashboard, or run Publish Chrome Extension with
      the next Stable version. Tick `stage_only` to hold the approved version until you publish it.
- [ ] **API access.** The Chrome Web Store API and the workload identity provider in `labs-851`
      haven't been tested end to end.
- [ ] **Decisions** in the next section.

## Decisions needed

1. **Summary text:** keep "Control Chrome with Codevisor." or use the proposed summary. It comes
   from the manifest, so changing it needs a new package.
2. **`history` and `clipboardRead`:** keep them as install-time permissions, or request them on
   first use.
3. **Reviewer access:** whether to give reviewers a test AI provider account.
