import { Eyebrow } from "../components/site-page"

export function SectionHead({ eyebrow, title }: { eyebrow: string; title: string }) {
  return (
    <div>
      <Eyebrow>{eyebrow}</Eyebrow>
      <h2 className="mt-2 text-[28px] leading-tight font-medium tracking-[-0.03em] sm:text-[36px]">
        {title}
      </h2>
    </div>
  )
}
