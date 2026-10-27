# DRAFT — plugin wording for the Terms and Privacy Policy

Status: draft for Dylan's legal review. Not published. The live pages (`apps/www/src/routes/terms.tsx`,
`apps/www/src/routes/privacy.tsx`) are unchanged. Nothing here ships until it is reviewed and copied in.

Each section below says where it goes and what it replaces. The last section lists every old claim
being replaced, quoted exactly.

---

## Terms

### Replaces Terms § "Providers, plugins, and websites", second paragraph

Plugins are MCP servers. A plugin can run as a program on your connected computer or connect to a
service hosted by its publisher. Installing a local plugin runs its code on that computer; connecting a
hosted plugin sends it the requests your agents make. A plugin can also show its own interface inside
a chat or as a pane, and can send events that start agent work. Browser features can make signed-in
website sessions available to an agent. Review what you install and connect, and grant only the access
you intend. We are responsible for the Services we provide; third parties are responsible for their
products, subject to applicable law.

### Replaces Terms § "Publishing and using plugins" (whole section). New title: "Plugins in Codevisor"

**Where plugins come from.** Codevisor's plugin catalog combines three sources: plugins we build and
ship with Codevisor ("Codevisor plugins"), a short list of popular plugins we choose ("Popular"), and
search results from the public MCP Registry operated by the Model Context Protocol project. You can
also add any MCP server yourself by its address or command ("custom plugins"). We don't host or
review third-party plugin code. A catalog listing, including a Popular listing or a registry result,
does not guarantee a third party's quality, safety, or data practices. Registry listings are published
under the MCP Registry's own terms by their publishers, not by us.

**Publishers.** If you publish a plugin that appears in Codevisor, you must have the rights to
distribute it, describe its functionality and data practices accurately, keep its metadata current,
and must not publish unlawful, abusive, deceptive, malicious, or objectionable content, or code that
bypasses our safeguards. Plugins that show user-generated content must moderate it and must not
conceal mature content behind an inaccurate rating.

**Age ratings.** Plugins in the catalog carry an age rating of 4, 9, 13, 16, or 18 under Apple's
age-rating criteria, set by us for Codevisor and Popular plugins and adjustable by us for any plugin.
Codevisor on iOS supports plugins rated 16+ or lower. On iOS, a catalog plugin rated above that, or
without a rating, cannot be installed from iOS, and its in-chat interface and panes do not open on iOS;
the reason is shown instead. Its tools may still run on your computer when an agent uses them.

**Plugins you add yourself.** A custom plugin you add by its address or command is your own choice of
software, not something Codevisor offers or lists. It is not age-rated by us, and its in-chat interface
and panes open on all your devices, including iOS. You are responsible for the custom plugins you add.
Report and Block still apply to them, and blocks we or you place on their publisher still take effect.

**Reporting and blocking.** Every plugin has Report and Block options: in the catalog, in Settings ›
Plugins, and next to any plugin interface shown in a chat or pane. We review reports promptly and may
contact the publisher, change the plugin's age rating, or remove or block it from the catalog or iOS
app, including for safety, privacy, age suitability, legal obligations, or App Store requirements.
Blocking a publisher hides its plugins' interfaces on your iOS devices. You can also reach us at
hello@codevisor.dev. These restrictions do not necessarily stop software already running independently
on your Mac.

**Your consent.** Before a plugin is installed, Codevisor shows which plugin will receive your consent.
Installing allows that plugin to run on, or be called from, your connected computers, to receive
the requests your agents send it and the information you enter in its interface, and, if you sign in
to an account for it, to act with that account's access. It does not grant the plugin iPhone system
permissions such as camera, microphone, location, or contacts. Plugins must obtain any additional
consent their own processing requires and provide appropriate privacy information.

**Accounts and events.** When you connect an account to a plugin, the plugin acts with that
account's access when your agents use it. If you or an agent subscribe to a plugin's events, matching
events can start agent work without a new message from you, within the limits Codevisor applies.
You are responsible for what you ask agents to do with those events, including messages they send on
your behalf.

---

## Privacy Policy

### Replaces Privacy § "Plugins and connected services" (whole section)

**Catalog and search.** Browsing plugins requests the catalog of Codevisor and Popular plugins from
Cloud. When you search, your computer also sends the search text to the public MCP Registry
(registry.modelcontextprotocol.io), which processes it under its own policies. Installing a plugin
from the registry can download its code from package services such as npm, PyPI, or container
registries, and connecting a hosted plugin contacts its publisher's server.

**Consent, reports, and blocks.** When you install a plugin through the app, we record your
permission for that plugin in your Cloud account so it applies across your devices. The record
includes the plugin's identifier (its catalog name, or for a plugin you add yourself, its host or
command name), a hash identifying the version you approved, the notice version, and the time you
agreed. We keep an account-only index with each approved plugin's name, publisher, description,
version, age rating, and the number of tools, events, skills, and panes it offers. The record does not
contain your workspace files, local paths, or credentials. We also store publishers you block so your
iOS devices respect that choice.

Plugin reports include your account identifier, the plugin's identifier and name, your selected
reason, any details you enter, and the report time. We store reports in our Cloud database and notify
our team through Slack with the report identifier, plugin, reason, and details. Avoid including
secrets or sensitive personal information. We use these records to investigate abuse, enforce our
terms, and maintain safety. Account deletion removes consent and publisher-block records and removes
your account link from retained reports. Reports and related Slack notifications may be retained as
needed for investigations, repeat-abuse prevention, legal obligations, and resolving disputes.

**What plugins receive.** Local plugins run on your connected computer and can access files and other
resources available to their process. Hosted plugins run on their publisher's servers. Either kind
receives the requests your agents make to it, including any content those requests contain, and the
information you enter in its interface. A plugin's in-chat interface or pane is a web page provided by
the plugin and shown in an isolated frame. It can load content from the sites the plugin declares,
which then receive your network address and similar request information. Results a plugin returns
for its interface are stored on the computer that ran the request for up to 30 days.

**Plugin accounts and secrets.** When you connect an account to a plugin, Codevisor keeps the
account's name, the identity the provider reports (such as an email address), and the non-secret
settings you entered, and synchronizes them across your devices. Passwords, API keys, and sign-in
tokens are stored in Codevisor's credential vault: each one is encrypted on your computer with its own
key before it is stored in Cloud, and the key is shared only between your devices through their
encrypted connections. Cloud stores the encrypted credential and coordinates which of your computers
refreshes it, but cannot read it. Plugins receive a short-lived access token or the specific settings
they need for each request, not refresh tokens.

**Signing in from any device.** Some sign-ins finish through a Cloud address. The provider sends the
one-time sign-in code to Cloud, which immediately encrypts it to the computer that started the
sign-in and holds it for at most 10 minutes until that computer collects it. The code cannot be used
without a secret that stays on that computer.

**Webhook inbox.** Some plugins receive notifications from other services, such as alerts. For those,
Cloud gives you a private inbox address. When a service sends to it, Cloud encrypts the request
(including its body and headers, minus cookies) separately for each of your computers that is
listening for that plugin, using each computer's own key, and stores only those encrypted copies until
each computer collects it or for at most 7 days. Cloud sees the request only while encrypting it and
cannot read the stored copies. Cloud keeps the inbox's identifier and which account, plugin, and
plugin account it belongs to, and counts requests to limit abuse. You can remove an inbox by
disconnecting the plugin account.

**Events.** Events a plugin reports are stored on the computer that received them so agents can read
them, and older events are deleted automatically. Event subscriptions are stored on the computer
where the agent runs.

**Removing a plugin.** Removing a plugin, a plugin account, or a credential stops the access that
depends on it and deletes Codevisor's copy of that credential; it does not delete information the
plugin's publisher or the provider already holds. Use their controls or contact them for deletion.

### Addition to Privacy § "Storage and retention", second paragraph

Encrypted webhook inbox items are deleted when each listening computer has collected them or after
7 days, and encrypted sign-in codes after 10 minutes. Encrypted plugin credentials remain until you
remove the account or credential.

---

## Old claims this draft replaces (quoted exactly from the live pages)

Terms, § "Providers, plugins, and websites":

1. "Installing a plugin can run code on your connected computer." → replaced by the local/hosted
   plugin paragraph (hosted plugins don't run code on your computer).

Terms, § "Publishing and using plugins": 2. "By submitting a plugin to our registry, including by publishing a repository with the
codevisor-plugin topic, you agree to these publisher requirements." → there is no Codevisor
registry or GitHub-topic submission any more; publisher duties now apply to any plugin that
appears in Codevisor, and registry listings fall under the MCP Registry's terms. 3. "Declare an ageRating of 4, 9, 13, 16, or 18 in the plugin manifest" → there is no Codevisor
manifest; we set or adjust ratings for catalog plugins. 4. "Plugins with a higher or missing rating cannot open on iOS." → now specific: catalog plugins with
a higher or missing rating can't be installed from iOS and their in-chat interface and panes don't
open on iOS; their tools may still run on the computer. Custom plugins you add yourself are outside
the age-rating gate and open on iOS; Report and Block still apply. 5. "We may review, filter, remove, or restrict any plugin or publisher from the registry or iOS app"
→ "from the catalog or iOS app". 6. "Report a plugin using its flag button." → Report and Block options in the catalog, Settings ›
Plugins, and next to any plugin interface in a chat or pane, plus hello@codevisor.dev. 7. "receive workspace context and information you provide through its panes or tools across your
connected devices" → receives agent requests and information entered in its interface; adds
connected-account access. 8. "Unlisted plugins are not endorsed by Codevisor." → replaced by the statement that no catalog
listing (Popular or registry) guarantees quality or safety.

Privacy, § "Plugins and connected services": 9. "The record includes its identifier, a hash identifying its source" → identifier is now the catalog
name or, for custom plugins, host or command name; the hash identifies the approved version. 10. "We keep an account-only index with its name, description, version, age rating, pane titles, and
tool descriptions, including for unlisted plugins you approve." → index now holds name, publisher,
description, version, age rating, and counts of tools, events, skills, and panes. 11. "The consent record does not contain your workspace files, local paths, or repository
credentials." → "workspace files, local paths, or credentials". 12. "Plugins run on your connected computer and can display a pane inside Codevisor or add agent
tools." → plugins may be local or hosted, and can also show in-chat interfaces and send events. 13. "Their panes receive workspace context, including the working directory and pane identifiers." →
removed; panes and in-chat interfaces receive only what the plugin returns and what you enter. 14. "Installing a plugin runs its declared commands on that computer." → only local plugins run code. 15. "Review the source, commands, tools, and privacy information of a plugin before installing it." →
kept in spirit in the Terms consent paragraph. 16. "Browsing the plugin directory requests catalog information from Cloud, and installation can
download code from the source repository and package services." → catalog comes from Cloud; search
text goes to the MCP Registry; installation of registry plugins can download code from package
services (npm, PyPI, container registries).

New subjects the old pages didn't cover at all: plugin accounts and the credential vault, the Cloud
sign-in relay, the webhook inbox and its 7-day encrypted queue, plugin events, and the 30-day local
storage of plugin interface results.

## Decisions reflected in this draft

- Custom plugins (added by address or command) are the user's own software: outside the age-rating
  gate, their interfaces open on iOS with no extra confirmation, and Report and Block still apply
  (Dylan, 2026-10-27).

## Open questions for review

- The Report link on the website directory is an email address; in the apps, reports go to Cloud.
- Timely-response commitment for reports is stated as "promptly"; replace with a concrete target if
  you want one.
