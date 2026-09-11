import { createFileRoute } from "@tanstack/react-router"

import { LegalPage } from "../components/legal-page"

export const Route = createFileRoute("/terms")({
  head: () => ({
    meta: [
      { title: "Terms of Service — Codevisor" },
      {
        name: "description",
        content:
          "Terms for Codevisor accounts, Cloud connections, AI agents, plugins, and hosted services."
      }
    ]
  }),
  component: TermsOfService
})

const sections = [
  {
    id: "agreement",
    title: "Your agreement with Codevisor",
    body: (
      <>
        <p>
          These Terms of Service are between you and 851 Inc. (“Codevisor,” “we,” or “us”). They
          govern Codevisor Cloud, our website, and the services we provide through our desktop and
          iOS apps and optional browser extension (the “Services”). Software licenses are addressed
          separately below.
        </p>
        <p>
          By selecting a button that states you agree to these terms, or otherwise expressly
          accepting them, you agree to this contract. If you do not agree, do not create an account
          or use our hosted Services. You must be legally able to enter this agreement. If you need
          a parent or guardian’s permission under applicable law, they must agree on your behalf. If
          you accept for an organization, you must have authority to bind it, and “you” includes
          that organization.
        </p>
        <p>
          These terms cover services operated by 851 Inc. If you use a Cloud server operated by
          someone else, that operator’s terms apply to its service. These terms do not restrict
          rights granted by the separate software licenses described below.
        </p>
      </>
    )
  },
  {
    id: "accounts",
    title: "Accounts and connected machines",
    body: (
      <>
        <p>
          Provide accurate account information and keep your sign-in accounts, devices, connection
          credentials, and provider keys secure. Only connect computers, repositories, browser
          sessions, and service accounts that you own or have permission to use. You are responsible
          for the access you grant and for activity you authorize through your account.
        </p>
        <p>
          Tell us promptly at <a href="mailto:hello@codevisor.dev">hello@codevisor.dev</a> if you
          believe your Codevisor account has been compromised. Remove affected connections and
          revoke credentials through the relevant provider. Codevisor Cloud helps connect devices;
          it is not a backup service for files or work on your computers.
        </p>
      </>
    )
  },
  {
    id: "agents",
    title: "AI agents and automated actions",
    body: (
      <>
        <p>
          Codevisor lets you direct agent tools on connected computers. Depending on the task and
          permissions you configure, an agent can read, create, change, or delete files, execute
          terminal commands, install software, access websites, and send information or take actions
          through connected accounts. Some actions can spend money or have effects that cannot
          easily be reversed.
        </p>
        <p>
          You authorize the actions you request and the access you enable. Review agent permissions
          and approval settings, keep backups, and check changes before using them in production or
          sharing them. Turning off an approval prompt or allowing unattended work can permit an
          agent to act without asking again. Disconnecting your phone or closing the app may not
          stop a task already running on a connected computer.
        </p>
        <p>
          AI output can be inaccurate, incomplete, insecure, or similar to other users’ output. We
          do not guarantee its correctness, originality, or suitability for your purpose. You are
          responsible for evaluating output and obtaining any permissions needed to use it. Do not
          rely on the Services as the sole safeguard for decisions or systems where an error could
          cause serious harm.
        </p>
      </>
    )
  },
  {
    id: "content",
    title: "Your code and content",
    body: (
      <>
        <p>
          You retain your rights in the prompts, code, files, attachments, and other material you
          provide (“Your Content”). We do not claim ownership of Your Content or AI output merely
          because you use Codevisor. Rights in output may depend on applicable law, the selected
          provider’s terms, and any third-party material it contains.
        </p>
        <p>
          You give us a limited, nonexclusive permission to process, store, and transmit Your
          Content only as needed to provide and secure the Services you use and carry out your
          instructions. This includes using service providers for those purposes as described in our{" "}
          <a href="/privacy">Privacy Policy</a>. This permission does not give us a general right to
          publish your private projects, sell Your Content, or use it to train AI models.
        </p>
        <p>
          You must have the rights and permissions needed to provide Your Content and direct its
          use, including permission to share another person’s information or your employer’s code.
          Retention and deletion are described in our Privacy Policy. Third-party providers you
          choose handle the content they receive under their own terms and policies.
        </p>
      </>
    )
  },
  {
    id: "third-parties",
    title: "Providers, plugins, and websites",
    body: (
      <>
        <p>
          AI providers, agent tools, plugins, websites, and other integrations are separate
          products. You choose which to use and must follow their applicable terms, eligibility
          requirements, and account limits. Their availability, behavior, security, and treatment of
          your data can change independently of Codevisor. A directory listing or integration does
          not guarantee a third party’s quality or safety.
        </p>
        <p>
          Installing a plugin can run code on your connected computer. Browser features can make
          signed-in website sessions available to an agent. Review what you install and connect, and
          grant only the access you intend. We are responsible for the Services we provide; third
          parties are responsible for their products, subject to applicable law.
        </p>
      </>
    )
  },
  {
    id: "fees",
    title: "Fees and provider charges",
    body: (
      <>
        <p>
          Codevisor does not include third-party subscriptions, API credits, hosting, or network
          service unless an offer expressly says so. You are responsible for charges from the
          providers you use, including usage generated by agents you authorize. Those providers
          handle their own billing, cancellation, and refunds.
        </p>
        <p>
          Agreeing to these terms does not by itself authorize a charge from Codevisor. Any paid
          Codevisor offer will disclose its price, billing period, renewal terms, and cancellation
          conditions before you purchase. Applicable purchase terms and mandatory refund rights
          govern that purchase.
        </p>
      </>
    )
  },
  {
    id: "acceptable-use",
    title: "Acceptable use",
    body: (
      <>
        <p>When using our Services, you must not:</p>
        <ul>
          <li>
            Break applicable law or infringe another person’s intellectual property or privacy.
          </li>
          <li>Access computers, accounts, data, or systems without authorization.</li>
          <li>Distribute malware, steal credentials, commit fraud, or facilitate abuse.</li>
          <li>Harass, exploit, threaten, or unlawfully discriminate against others.</li>
          <li>
            Interfere with our hosted infrastructure or other users, evade service access controls
            or usage limits, or conduct unauthorized security testing against our hosted systems.
          </li>
          <li>Use the Services in violation of applicable export controls or sanctions.</li>
        </ul>
        <p>
          These restrictions govern use of our Services. They do not prohibit activities that an
          applicable open-source license or law permits with separately licensed software. Report
          suspected security issues to <a href="mailto:hello@codevisor.dev">hello@codevisor.dev</a>.
        </p>
      </>
    )
  },
  {
    id: "privacy",
    title: "Privacy and permissions",
    body: (
      <p>
        Our <a href="/privacy">Privacy Policy</a> explains what information the Services handle, who
        receives it, and your choices for retention, deletion, and sharing. Accepting these terms
        does not replace any separate consent required for AI data sharing, optional analytics, or
        device permissions. You can manage those choices through the relevant app, device, or
        provider controls. Withdrawing a permission may make features that depend on it unavailable.
      </p>
    )
  },
  {
    id: "licenses",
    title: "Software licenses and Apple",
    body: (
      <>
        <p>
          Codevisor’s open-source code is provided under the licenses included with that code,
          including the GNU Affero General Public License v3.0 in our{" "}
          <a href="https://github.com/851-labs/codevisor/blob/main/LICENSE">source repository</a>.
          Those licenses govern your rights to use, copy, modify, and distribute the covered
          software and take priority over these terms for that software. Other included components
          retain their respective licenses. These terms do not grant ownership of Codevisor’s
          trademarks or branding.
        </p>
        <p>
          For the Codevisor app obtained through Apple’s App Store, Apple’s{" "}
          <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">
            Standard End User License Agreement
          </a>{" "}
          applies to the app license, subject to its provisions for open-source components. These
          service terms supplement that agreement and do not replace it or limit rights granted by
          applicable open-source licenses. If these terms conflict with the Standard EULA on an
          app-license matter, the Standard EULA controls, including its open-source exceptions.
        </p>
        <p>
          This service agreement is with 851 Inc., not Apple. Direct questions about Codevisor and
          requests for support to <a href="mailto:hello@codevisor.dev">hello@codevisor.dev</a>.
          Nothing here changes Apple’s obligations under applicable law or its agreements with you.
        </p>
      </>
    )
  },
  {
    id: "availability",
    title: "Availability and changes to the Services",
    body: (
      <>
        <p>
          Features can depend on your connected computer, network, operating system, agent tool, and
          third-party services. We do not promise uninterrupted access, a particular response time,
          or that every integration will remain available. Preview and beta features may be
          incomplete or change before release.
        </p>
        <p>
          We may maintain, update, change, or discontinue hosted features. We will give reasonable
          advance notice of a material reduction or shutdown when practicable, except where urgent
          security, legal, or operational needs require earlier action. Changes remain subject to
          commitments in any paid offer and your rights under applicable law.
        </p>
      </>
    )
  },
  {
    id: "termination",
    title: "Suspension, cancellation, and deletion",
    body: (
      <>
        <p>
          You may stop using the Services at any time. You can delete your Cloud account through the
          app’s account settings or contact us for assistance. Account deletion disconnects its
          registered machines but does not delete files or agent history on your computers, cancel
          third-party subscriptions, or necessarily stop tasks already running there. Manage those
          separately using the relevant computer or provider controls.
        </p>
        <p>
          We may restrict or suspend hosted access when reasonably necessary to address a material
          breach of these terms, security threats, unlawful activity, or harm to the Services or
          others. We may terminate an account for serious or repeated violations. When practicable
          and lawful, we will explain the reason and give you an opportunity to resolve the issue.
          Contact us if you believe a restriction was a mistake.
        </p>
        <p>
          Ending this agreement does not transfer ownership of Your Content or cancel rights under a
          separate software license. Provisions that by their nature should continue, including
          ownership, accrued payment obligations, limitations of liability, and dispute provisions,
          survive termination. Personal information is handled as described in our Privacy Policy.
        </p>
      </>
    )
  },
  {
    id: "warranties",
    title: "Warranties",
    body: (
      <p>
        To the extent permitted by law, the Services are provided “as is” and “as available.” We
        disclaim implied warranties of merchantability, fitness for a particular purpose, and
        noninfringement. We do not warrant that the Services or AI output will be error-free, secure
        in every circumstance, or suitable for every task. This section does not exclude warranties,
        service standards, or remedies that applicable law does not allow us to exclude, or any
        express commitments in a separate written agreement with you.
      </p>
    )
  },
  {
    id: "liability",
    title: "Limits on liability",
    body: (
      <>
        <p>
          To the extent permitted by law, 851 Inc. will not be liable for indirect, incidental,
          special, or consequential losses, including lost profits, lost business opportunities, or
          loss of data, arising from the Services. Our total liability for claims arising from these
          terms or the Services will not exceed the greater of US $100 or the amount you paid us for
          the Services in the 12 months before the event giving rise to the claim.
        </p>
        <p>
          These exclusions and limits do not apply to fraud, willful misconduct, gross negligence,
          death or personal injury caused by negligence, or any liability that cannot lawfully be
          excluded or limited. They do not reduce mandatory consumer remedies or override liability
          provisions in an applicable software license or separate written agreement.
        </p>
      </>
    )
  },
  {
    id: "disputes",
    title: "Disputes and your legal rights",
    body: (
      <p>
        If you have a concern, contact <a href="mailto:hello@codevisor.dev">hello@codevisor.dev</a>{" "}
        so we can try to resolve it. This does not prevent you from seeking relief from a court or
        regulator. These terms do not require arbitration, waive class actions, or take away
        protections that mandatory law gives you in your place of residence. Applicable law
        determines the governing law and courts with jurisdiction. If a provision is unenforceable,
        the remaining terms continue to apply to the extent permitted by law.
      </p>
    )
  },
  {
    id: "changes",
    title: "Updates to these terms",
    body: (
      <p>
        We may update these terms as the Services change. We will publish the revised terms and
        effective date on this page. For material changes, we will provide reasonable advance notice
        through the Services or your account email, unless an urgent legal or security need prevents
        it. Changes will apply prospectively, and we will request renewed agreement where required
        by law. If you do not agree to revised terms, you may stop using our hosted Services and
        delete your account.
      </p>
    )
  },
  {
    id: "contact",
    title: "Contact",
    body: (
      <p>
        Codevisor is operated by 851 Inc. For questions about these terms, support, account
        concerns, or legal notices, email{" "}
        <a href="mailto:hello@codevisor.dev">hello@codevisor.dev</a>.
      </p>
    )
  }
] as const

function TermsOfService() {
  return (
    <LegalPage
      title="Terms of Service"
      description="The terms for using Codevisor’s services, connecting your machines, and working with AI agents."
      effectiveDate="September 11, 2026"
      sectionsLabel="Terms sections"
      sections={sections}
    />
  )
}
