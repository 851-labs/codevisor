export const privacyGoogleSection = {
  id: "google",
  title: "Google user data and Gmail",
  body: (
    <>
      <p>
        <strong>What the Gmail plugin accesses.</strong> The optional Gmail plugin connects a Google
        account you choose. With your permission, it can read, compose, send, and organize that
        account’s email (Google’s <code>gmail.modify</code> scope) and see the account’s email
        address (the <code>openid</code> and <code>email</code> scopes). Codevisor uses this access
        only for the features you or your agents use: searching and reading messages and
        conversations, listing labels, creating and changing drafts, sending messages and replies
        after you approve the exact recipients, subject, and body, archiving, marking messages read
        or unread, and adding or removing labels. If an agent subscribes to new mail, the plugin
        also checks for messages arriving in your inbox so the agent can act on them.
      </p>
      <p>
        <strong>Where it is processed.</strong> The plugin runs on your own computer and talks to
        Gmail directly. Messages, drafts, labels, and new-mail events are processed on your
        computers. Codevisor’s servers do not store your Gmail data or receive it in a form we can
        read. When an agent uses Gmail, the content it reads becomes part of that chat: it is sent
        to the AI provider you chose for the agent so it can complete your request, as described
        above, and kept in your chat history on your computer. Chats you open on another of your
        devices travel through the Cloud relay encrypted between your devices.
      </p>
      <p>
        <strong>What passes through Cloud.</strong> For new-mail notifications, Gmail sends Cloud a
        notice through Google Cloud Pub/Sub with your email address and a mailbox change number
        (Gmail’s history ID). It contains no message content. Cloud finds your listening computers
        using a hash of your email address, which is the only form of your address it stores, and
        forwards the notice to them encrypted, as described under Webhook inbox. Your computers then
        fetch any new messages from Gmail directly. Your Google sign-in tokens are kept in
        Codevisor’s credential vault: encrypted on your computer, synchronized only between your own
        devices, and unreadable by Cloud.
      </p>
      <p>
        <strong>What we don’t do.</strong> We do not sell Google user data, transfer it to
        advertising platforms, data brokers, or other information resellers, or use it for
        advertising, retargeting, or to determine creditworthiness or for lending. We do not use it
        to develop, improve, or train AI or machine learning models. We transfer it only as needed
        to provide the features you use, such as to the AI provider you choose for your agent, for
        security purposes such as investigating abuse, to comply with law, or as part of a merger,
        acquisition, or sale of assets after obtaining your explicit prior consent. Your AI
        provider’s terms and account settings govern how it handles your requests, including whether
        they can be used for training. We do not allow humans to read your Google user data unless
        you first give us explicit permission for specific messages, such as for support, it is
        necessary for security purposes such as investigating a bug or abuse, or it is required by
        law.
      </p>
      <p>
        <strong>Revoking access and deleting data.</strong> To disconnect an account, choose Sign
        Out for it in Gmail’s plugin settings, or uninstall the plugin. Codevisor then stops Gmail
        notifications for the account, deletes its copy of the account’s sign-in tokens, and removes
        the account’s inbox and address hash from Cloud. You can also revoke Codevisor’s access at
        any time from your Google Account’s{" "}
        <a href="https://myaccount.google.com/connections">third-party connections</a> page. Email
        content in your chats stays in your chat history until you delete those chats, and new-mail
        events are deleted automatically. To ask us to delete information we hold, email{" "}
        <a href="mailto:hello@codevisor.dev">hello@codevisor.dev</a>. Content already sent to your
        AI provider is retained under that provider’s policies.
      </p>
      <p>
        <strong>Limited Use.</strong> Codevisor’s use and transfer of information received from
        Google APIs to any other app will adhere to the{" "}
        <a href="https://developers.google.com/terms/api-services-user-data-policy">
          Google API Services User Data Policy
        </a>
        , including the Limited Use requirements.
      </p>
    </>
  )
}
