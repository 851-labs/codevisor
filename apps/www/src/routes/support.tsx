import { createFileRoute } from "@tanstack/react-router"

import { HeroButton, PageHero, SitePage } from "../components/site-page"

export const Route = createFileRoute("/support")({
  head: () => ({
    meta: [
      { title: "Support — Codevisor" },
      { name: "description", content: "Get help with Codevisor. Email hello@codevisor.dev." }
    ]
  }),
  component: Support
})

function Support() {
  return (
    <SitePage>
      <PageHero title="Support" description="Need a hand? Send us an email.">
        <div className="mt-9 flex justify-center">
          <HeroButton href="mailto:hello@codevisor.dev">hello@codevisor.dev</HeroButton>
        </div>
      </PageHero>
    </SitePage>
  )
}
