export function SectionHead({ eyebrow, title }: { eyebrow: string; title: string }) {
  return (
    <div>
      <p className="text-[13px] font-semibold tracking-[0.08em] text-signal uppercase">{eyebrow}</p>
      <h2 className="mt-2 text-[28px] leading-tight font-medium tracking-[-0.03em] sm:text-[36px]">
        {title}
      </h2>
    </div>
  )
}
