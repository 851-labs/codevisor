import { createFileRoute } from "@tanstack/react-router"

import { LegalPage } from "../components/legal-page"

export const Route = createFileRoute("/privacy")({
  head: () => ({
    meta: [
      { title: "Privacy Policy — Codevisor" },
      {
        name: "description",
        content:
          "How Codevisor handles data across its apps, Cloud service, website, AI providers, and plugins."
      }
    ]
  }),
  component: PrivacyPolicy
})

const sections = [
  {
    id: "scope",
    title: "Who we are and what this covers",
    body: (
      <>
        <p>
          Codevisor is operated by 851 Inc. (“Codevisor,” “we,” or “us”). This policy covers our
          desktop and iOS apps, Codevisor Cloud, website, and optional Chrome extension. It also
          explains how using AI providers, browser features, and plugins can share information with
          other services. Contact us at <a href="mailto:hello@codevisor.dev">hello@codevisor.dev</a>
          .
        </p>
        <p>
          You choose the computers, agent tools, and services you connect. If you use a Cloud server
          hosted by someone else, that operator handles the account and connection data described
          below under its own policies. This policy governs the services we operate.
        </p>
      </>
    )
  },
  {
    id: "data",
    title: "Your work and device data",
    body: (
      <>
        <p>Depending on the features and tasks you use, Codevisor handles:</p>
        <ul>
          <li>Prompts, agent responses, conversation history, and tool inputs and results.</li>
          <li>
            Project information, code, file names and paths, terminal commands and output, and files
            an agent accesses on the connected computer while performing your task.
          </li>
          <li>
            Photos, files, screenshots, and other attachments you select, capture, or generate.
          </li>
          <li>Open-tab metadata, including page titles and URLs.</li>
          <li>Web history results when you or your agent explicitly searches Chrome history.</li>
          <li>
            Website content and resources needed to inspect or interact with a page, including text,
            images, links, form fields, and page structure.
          </li>
          <li>
            Browser actions and task artifacts, such as clicks, typed text, uploads, downloads, and
            dialog responses, plus browsing history and website cookies used by browser panes.
          </li>
          <li>
            Clipboard content only when a requested task reads from or writes to the clipboard.
          </li>
          <li>Local preferences, drafts, connection credentials, and cached workspace state.</li>
        </ul>
        <p>
          Pages, files, history results, or clipboard content you choose to use may contain personal
          identifiers, communications, authentication information, or other sensitive content. The
          iOS app communicates with your connected computer to run agent and terminal tasks. The
          apps and connected computer can keep local history, attachments, and caches so you can
          return to your work. Relevant task content can also reach the providers described below.
        </p>
      </>
    )
  },
  {
    id: "cloud",
    title: "Accounts and Codevisor Cloud",
    body: (
      <>
        <p>
          Cloud connects your devices through an account. When you sign in with Apple or GitHub, we
          receive a provider account identifier and the profile information the provider supplies,
          such as your name, email address, and profile image. Apple may supply a private relay
          email address. We store linked sign-in records and authentication tokens needed to
          maintain your account and revoke Apple authorization when you delete it.
        </p>
        <p>
          Cloud stores registered-machine names and identifiers, operating system and app version,
          public encryption keys, connection status, and last-seen times. Authentication and
          operational records can include IP addresses, browser or device information, timestamps,
          connection identifiers, errors, and traffic counts and sizes. We use these records to
          authenticate devices, route connections, prevent abuse, and diagnose service failures.
        </p>
        <p>
          Cloudflare hosts our Cloud service and processes network requests. Cloud uses IP-derived
          location estimates supplied by Cloudflare to select a nearby service region; this does not
          use your device’s GPS permission. Cloud temporarily buffers encrypted messages to allow
          interrupted connections to resume. Account and connection metadata remain accessible to
          the service even when message contents are encrypted.
        </p>
      </>
    )
  },
  {
    id: "use",
    title: "AI providers and agent tools",
    body: (
      <>
        <p>
          The agent tool running on your connected computer sends requests to its configured model
          provider. A request can include your prompt, relevant conversation history, code, files,
          images, browser content, and tool results needed for the task. An agent can also send
          information to websites or connected services when carrying out your instructions.
        </p>
        <p>
          The recipients depend on the agent, model, integrations, and account you configure.
          Provider policies include those of{" "}
          <a href="https://openai.com/policies/privacy-policy/">OpenAI</a>,{" "}
          <a href="https://www.anthropic.com/legal/privacy">Anthropic</a>,{" "}
          <a href="https://policies.google.com/privacy">Google</a>,{" "}
          <a href="https://cursor.com/privacy">Cursor</a>, and{" "}
          <a href="https://x.ai/legal/privacy-policy">xAI</a>. For other or custom providers,
          consult the operator of the endpoint configured in your agent tool.
        </p>
        <p>
          Providers handle requests under the terms for your account or API service. Retention,
          human review, and use for model training can vary by provider, product, and account
          settings. Cloud relay encryption does not prevent your selected provider from receiving
          task content. Review those settings before sending information, and stop using a provider
          or remove its credentials to stop future requests to it.
        </p>
      </>
    )
  },
  {
    id: "browser",
    title: "Browser features",
    body: (
      <>
        <p>
          Browser Use is optional. The Chrome extension connects to Codevisor on the same computer
          so an agent can inspect and interact with your existing Chrome session. It handles tab
          information, requested history searches, page content, and browser actions for your task.
          Chrome displays its debugging indicator while Codevisor controls a tab.
        </p>
        <p>
          Codevisor also offers a separate managed browser and browser panes. Browser panes can
          route web traffic through the selected computer and synchronize browsing state and website
          cookies with that computer. Cookies may keep you signed in to websites, so this can make
          an authenticated website session available to the connected browser profile. Browser and
          plugin web views may store cookies, local storage, and cached content. Websites you visit
          receive requests and handle information under their own policies.
        </p>
      </>
    )
  },
  {
    id: "plugins",
    title: "Plugins and connected services",
    body: (
      <>
        <p>
          When you install a plugin through the app, we record your permission for that individual
          plugin in your Cloud account so it applies across your devices. The record includes its
          identifier, a hash identifying its source, the notice version, and the time you agreed. We
          keep an account-only index with its name, description, version, age rating, pane titles,
          and tool descriptions, including for unlisted plugins you approve. The consent record does
          not contain your workspace files, local paths, or repository credentials. We also store
          publishers you block so your iOS devices respect that choice.
        </p>
        <p>
          Plugin reports include your account identifier, the plugin’s identifier and name, your
          selected reason, any details you enter, and the report time. We store reports in our Cloud
          database and notify our team through Slack with the report identifier, plugin, reason, and
          details. Avoid including secrets or sensitive personal information. We use these records
          to investigate abuse, enforce our terms, and maintain safety. Account deletion removes
          consent and publisher-block records and removes your account link from retained reports.
          Reports and related Slack notifications may be retained as needed for investigations,
          repeat-abuse prevention, legal obligations, and resolving disputes.
        </p>
        <p>
          Plugins run on your connected computer and can display a pane inside Codevisor or add
          agent tools. Their panes receive workspace context, including the working directory and
          pane identifiers. Installing a plugin runs its declared commands on that computer.
          Depending on its code, a plugin can access files and other resources available to its
          process and send information to external services.
        </p>
        <p>
          Review the source, commands, tools, and privacy information of a plugin before installing
          it. Removing a plugin or a service credential stops the access that depends on it; it does
          not delete information the provider already holds. Use that provider’s controls or contact
          it for deletion. Browsing the plugin directory requests catalog information from Cloud,
          and installation can download code from the source repository and package services.
        </p>
      </>
    )
  },
  {
    id: "analytics",
    title: "Optional usage analytics",
    body: (
      <>
        <p>
          Usage analytics in the macOS app is off by default. If you enable it, Codevisor sends
          selected product events to PostHog, such as opening the app, creating a chat, sending a
          message, selecting a model or agent, and whether a turn completed. Events may include the
          app version, operating system, processor architecture, coarse usage ranges, and
          automatically generated analytics identifiers.
        </p>
        <p>
          Analytics events do not include prompts, responses, code, file or project names, paths,
          browser content, or terminal commands. We disable PostHog person profiles and IP-based
          geolocation for these events. The current iOS app does not send these analytics events.
          App analytics preferences do not control Cloud operational records or website analytics.
        </p>
      </>
    )
  },
  {
    id: "diagnostics",
    title: "Optional crash and error reports",
    body: (
      <>
        <p>
          Crash and error reporting in the macOS app is off by default. If you enable it, Codevisor
          uses Sentry to receive native crash stack traces and selected internal error identifiers.
          Reports may include the Codevisor version and build, macOS name and version, processor
          architecture, loaded binary identifiers needed for symbolication, and technical stack
          frames.
        </p>
        <p>
          We disable session recording, screenshots, automatic activity and network capture, and
          performance tracing. Before sending a report, Codevisor removes user and request details,
          exception messages, and directory paths from technical stack traces.
        </p>
        <p>
          Reports are designed not to include prompts, responses, code, file paths, project names,
          browser content, terminal commands, or account identifiers. The current iOS app does not
          send these reports to Sentry. These settings do not control diagnostic information you
          separately choose to share with Apple through your device or TestFlight.
        </p>
      </>
    )
  },
  {
    id: "website",
    title: "Website analytics and cookies",
    body: (
      <>
        <p>
          Our website uses PostHog to measure page views and interactions with installation
          instructions, including the installation method selected or copied. Events include page
          paths, browser and device information, and automatically generated identifiers. This
          website measurement runs separately from the optional analytics in the native app.
        </p>
        <p>
          Website analytics uses memory-only storage, with persistent analytics cookies and local
          storage disabled. We disable session recording, automatic interaction capture, person
          profiles, and IP-based geolocation. Network providers still receive IP addresses when
          handling requests. Cloud sign-in pages and external websites may use cookies needed to
          authenticate you and maintain their own sessions.
        </p>
      </>
    )
  },
  {
    id: "sharing",
    title: "Service providers and other sharing",
    body: (
      <>
        <p>
          <a href="https://www.cloudflare.com/privacypolicy/">Cloudflare</a> provides hosting,
          databases, and network services. <a href="https://posthog.com/privacy">PostHog</a>{" "}
          processes analytics, and <a href="https://sentry.io/privacy/">Sentry</a> processes enabled
          crash and error reports. <a href="https://www.apple.com/legal/privacy/">Apple</a> and{" "}
          <a href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement">
            GitHub
          </a>{" "}
          process sign-in requests when you choose those providers.
        </p>
        <p>
          Service providers processing personal information on our behalf must protect it
          consistently with this policy and use it to provide their contracted services. AI
          accounts, websites, plugins, and services you connect also have their own terms and
          privacy controls, as described above.
        </p>
        <p>
          We do not sell browser data, use it for advertising, or use it to determine
          creditworthiness or for lending. We do not permit employees or contractors to read browser
          content except with your explicit consent for support, when necessary for security, or
          when required by law. Codevisor’s use and transfer of information received from Google
          APIs complies with the Chrome Web Store User Data Policy, including its Limited Use
          requirements.
        </p>
        <p>
          We may disclose information we hold to comply with law, address security or abuse, protect
          users and our legal rights, or carry out a merger, acquisition, or other business
          transfer, subject to applicable privacy requirements. If you contact support, we use your
          contact details and the information you send to respond to your request.
        </p>
      </>
    )
  },
  {
    id: "retention",
    title: "Storage and retention",
    body: (
      <>
        <p>
          Local conversations, attachments, browser state, and agent-tool records remain on the
          devices or computers that store them until removed through the relevant app, tool, or
          device controls. The Chrome extension keeps the connection and tab state needed for
          Browser Use; the connected app and agent tools can separately retain task history.
        </p>
        <p>
          We retain Cloud account and machine-registration records to provide your account until you
          delete the account or remove the machine. Successful account deletion removes active
          account, linked sign-in, session, and machine-credential records and clears the account’s
          relay state. Encrypted reconnection buffers are cleared after delivery or when the
          reconnection session ends.
        </p>
        <p>
          Operational logs, support correspondence, analytics, and diagnostics have retention
          criteria based on their purpose: maintaining the service, investigating failures or abuse,
          resolving your request, and understanding product usage. Provider retention settings and
          any legal preservation requirements also affect how long these records remain. Deleting an
          account does not immediately erase copies in provider-managed backups or previously
          collected analytics and logs. You can request deletion of personal information we hold at{" "}
          <a href="mailto:hello@codevisor.dev">hello@codevisor.dev</a>.
        </p>
        <p>
          AI providers, plugin services, websites, and operators of servers you choose apply their
          own retention policies. Your device or computer backups may also retain local data under
          the backup settings you control.
        </p>
      </>
    )
  },
  {
    id: "security",
    title: "Security and processing locations",
    body: (
      <>
        <p>
          Cloud relay message contents are encrypted between your devices. The relay routes and
          temporarily buffers encrypted messages without decrypting their contents. This protection
          applies to relayed task content; Cloud still processes account, authentication, and
          connection metadata. The connected computer and selected AI or tool provider receive the
          content they need to perform your task.
        </p>
        <p>
          Hosted Cloud connections use HTTPS and secure WebSockets. Direct connections use the
          transport you configure, such as HTTPS, a private network tunnel, or local HTTP. Plain
          HTTP alone does not encrypt traffic. Native apps use the system keychain for their stored
          machine and Cloud credentials. The Chrome extension connects to Codevisor through a
          loopback address on the same computer.
        </p>
        <p>
          Our infrastructure and service providers can process information in the United States and
          other countries where they operate. Cloud routing selects a nearby region where available;
          it is not a guarantee that all data remains in your country. Providers you configure and
          computers you connect have their own processing locations.
        </p>
      </>
    )
  },
  {
    id: "controls",
    title: "Your controls",
    body: (
      <>
        <p>You can control sharing and stored information in several ways:</p>
        <ul>
          <li>
            On macOS, turn usage analytics and crash reporting on or off independently in Settings →
            Privacy &amp; Data. Turning them off stops future app reporting; request deletion
            separately for information already received.
          </li>
          <li>
            On iOS, review AI data sharing or choose Withdraw AI consent in Settings → Privacy &amp;
            Data. Withdrawing returns that device to the consent screen, where you must agree again
            to continue. It does not stop tasks already running on connected computers or delete
            information a provider has already received.
          </li>
          <li>
            Choose Settings → Account → Delete Cloud Account to delete your Cloud account and
            disconnect its machines. Apple authorization is revoked as part of deletion. You may
            need to sign in again to confirm your identity. Files and chats on your computers
            remain.
          </li>
          <li>
            On iOS, choose Settings → Privacy &amp; Data → Delete All Data to reset that device’s
            Codevisor state, saved connections, and sign-in. This does not delete your Cloud account
            or data on connected computers. Browser profiles, plugins, and agent tools can keep
            separate data that needs to be removed through their own controls.
          </li>
          <li>
            Stop agent tasks, remove connected machines, uninstall plugins, and remove provider
            credentials to stop the access that depends on those connections.
          </li>
          <li>
            Control camera and local-network permissions through your device’s system settings.
          </li>
          <li>Stop Browser Use from Codevisor.</li>
          <li>Choose Codevisor’s separate managed browser instead of your Chrome session.</li>
          <li>Disable or uninstall the Codevisor extension in Chrome.</li>
          <li>
            Use the relevant computer or agent tool’s controls to remove its conversations and
            files.
          </li>
          <li>
            Manage Chrome history and operating-system clipboard content using their controls.
          </li>
        </ul>
      </>
    )
  },
  {
    id: "rights",
    title: "Privacy requests",
    body: (
      <p>
        Depending on applicable law, you may have rights to access, correct, delete, or receive a
        copy of your personal information, withdraw consent, or object to or restrict certain
        processing. Contact <a href="mailto:hello@codevisor.dev">hello@codevisor.dev</a> to make a
        request. We may need to verify your identity and explain any information we are legally
        required to retain. You may also have the right to complain to your local data protection
        authority. For information held by a provider you use directly, contact that provider.
      </p>
    )
  },
  {
    id: "changes",
    title: "Changes and contact",
    body: (
      <p>
        We may update this policy as Codevisor changes. The effective date identifies the current
        version. Send questions or privacy requests to{" "}
        <a href="mailto:hello@codevisor.dev">hello@codevisor.dev</a>.
      </p>
    )
  }
] as const

function PrivacyPolicy() {
  return (
    <LegalPage
      title="Privacy, in plain language."
      description="Understand what stays on your devices, what Codevisor Cloud handles, and what reaches your AI providers and connected services — plus your choices for sharing and deletion."
      effectiveDate="September 11, 2026"
      sectionsLabel="Privacy sections"
      sections={sections}
    />
  )
}
