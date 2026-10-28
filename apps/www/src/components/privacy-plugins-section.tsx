export const privacyPluginsSection = {
  id: "plugins",
  title: "Plugins and connected services",
  body: (
    <>
      <p>
        <strong>Catalog and search.</strong> Browsing plugins requests the catalog of Codevisor and
        Popular plugins from Cloud. When you search, your computer also sends the search text to the
        public MCP Registry (registry.modelcontextprotocol.io), which processes it under its own
        policies. Installing a plugin from the registry can download its code from package services
        such as npm, PyPI, or container registries, and connecting a hosted plugin contacts its
        publisher’s server.
      </p>
      <p>
        <strong>Consent, reports, and blocks.</strong> When you install a plugin through the app, we
        record your permission for that plugin in your Cloud account so it applies across your
        devices. The record includes the plugin’s identifier (its catalog name, or for a plugin you
        add yourself, its host or command name), a hash identifying the version you approved, the
        notice version, and the time you agreed. We keep an account-only index with each approved
        plugin’s name, publisher, description, version, age rating, and the number of tools, events,
        skills, and panes it offers. The record does not contain your workspace files, local paths,
        or credentials. We also store publishers you block so your iOS devices respect that choice.
      </p>
      <p>
        Plugin reports include your account identifier, the plugin’s identifier and name, your
        selected reason, any details you enter, and the report time. We store reports in our Cloud
        database and notify our team through Slack with the report identifier, plugin, reason, and
        details. Avoid including secrets or sensitive personal information. We use these records to
        investigate abuse, enforce our terms, and maintain safety. Account deletion removes consent
        and publisher-block records and removes your account link from retained reports. Reports and
        related Slack notifications may be retained as needed for investigations, repeat-abuse
        prevention, legal obligations, and resolving disputes.
      </p>
      <p>
        <strong>What plugins receive.</strong> Local plugins run on your connected computer and can
        access files and other resources available to their process. Hosted plugins run on their
        publisher’s servers. Either kind receives the requests your agents make to it, including any
        content those requests contain, and the information you enter in its interface. A plugin’s
        in-chat interface or pane is a web page provided by the plugin and shown in an isolated
        frame. It can load content from the sites the plugin declares, which then receive your
        network address and similar request information. Results a plugin returns for its interface
        are stored on the computer that ran the request for up to 30 days.
      </p>
      <p>
        <strong>Plugin accounts and secrets.</strong> When you connect an account to a plugin,
        Codevisor keeps the account’s name, the identity the provider reports (such as an email
        address), and the non-secret settings you entered, and synchronizes them across your
        devices. Passwords, API keys, and sign-in tokens are stored in Codevisor’s credential vault:
        each one is encrypted on your computer with its own key before it is stored in Cloud, and
        the key is shared only between your devices through their encrypted connections. Cloud
        stores the encrypted credential and coordinates which of your computers refreshes it, but
        cannot read it. Plugins receive a short-lived access token or the specific settings they
        need for each request, not refresh tokens.
      </p>
      <p>
        <strong>Signing in from any device.</strong> Some sign-ins finish through a Cloud address.
        The provider sends the one-time sign-in code to Cloud, which immediately encrypts it to the
        computer that started the sign-in and holds it for at most 10 minutes until that computer
        collects it. The code cannot be used without a secret that stays on that computer.
      </p>
      <p>
        <strong>Webhook inbox.</strong> Some plugins receive notifications from other services, such
        as alerts. For those, Cloud gives you a private inbox address. When a service sends to it,
        Cloud encrypts the request (including its body and headers, minus cookies) separately for
        each of your computers that is listening for that plugin, using each computer’s own key, and
        stores only those encrypted copies until each computer collects it or for at most 7 days.
        Cloud sees the request only while encrypting it and cannot read the stored copies. Cloud
        keeps the inbox’s identifier and which account, plugin, and plugin account it belongs to,
        and counts requests to limit abuse. You can remove an inbox by disconnecting the plugin
        account.
      </p>
      <p>
        <strong>Events.</strong> Events a plugin reports are stored on the computer that received
        them so agents can read them, and older events are deleted automatically. Event
        subscriptions are stored on the computer where the agent runs.
      </p>
      <p>
        <strong>Removing a plugin.</strong> Removing a plugin, a plugin account, or a credential
        stops the access that depends on it and deletes Codevisor’s copy of that credential; it does
        not delete information the plugin’s publisher or the provider already holds. Use their
        controls or contact them for deletion.
      </p>
    </>
  )
}
