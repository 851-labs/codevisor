import { ThemedImage } from "./themed-image"

export type Shot = { src: string; alt: string }

const screenshot = (name: string) => ({
  light: `/screenshots/${name}.webp`,
  dark: `/screenshots/${name}-dark.webp`
})

const screenMask = (url: string) => ({
  maskImage: `url(${url})`,
  WebkitMaskImage: `url(${url})`,
  maskSize: "100% 100%",
  WebkitMaskSize: "100% 100%",
  maskRepeat: "no-repeat",
  WebkitMaskRepeat: "no-repeat"
})

const BEZEL = "pointer-events-none relative block h-auto w-full"

export function MacBookPro({ src, alt, eager = false }: Shot & { eager?: boolean }) {
  return (
    <div className="landing-noselect relative">
      <div
        className="absolute overflow-hidden"
        style={{
          left: "10.829%",
          top: "11.339%",
          width: "78.342%",
          height: "77.323%",
          ...screenMask("/devices/macbook-pro-14-screen-mask.png")
        }}
      >
        <ThemedImage
          {...screenshot(src)}
          alt={alt}
          width={3024}
          height={1964}
          eager={eager}
          className="absolute inset-0 h-full w-full"
        />
      </div>
      <ThemedImage
        light="/devices/macbook-pro-14-silver.webp"
        dark="/devices/macbook-pro-14-space-black.webp"
        alt=""
        width={2316}
        height={1524}
        eager={eager}
        className={BEZEL}
      />
    </div>
  )
}

export function IPhonePro({
  src,
  alt,
  eager = false,
  className = ""
}: Shot & { eager?: boolean; className?: string }) {
  return (
    <div className={`landing-noselect relative ${className}`}>
      <ThemedImage
        {...screenshot(src)}
        alt={alt}
        width={1206}
        height={2622}
        eager={eager}
        className="absolute"
        style={{
          left: "5.333%",
          top: "2.5%",
          width: "89.333%",
          height: "95%",
          ...screenMask("/devices/iphone-18-pro-screen-mask.png")
        }}
      />
      <ThemedImage
        light="/devices/iphone-18-pro-silver.webp"
        dark="/devices/iphone-18-pro-black.webp"
        alt=""
        width={810}
        height={1656}
        eager={eager}
        className={BEZEL}
      />
    </div>
  )
}

function IPadPro({ src, alt, eager = false }: Shot & { eager?: boolean }) {
  return (
    <div className="landing-noselect relative">
      <ThemedImage
        {...screenshot(src)}
        alt={alt}
        width={2420}
        height={1668}
        eager={eager}
        className="absolute"
        style={{
          left: "4.1667%",
          top: "5.6383%",
          width: "91.6667%",
          height: "88.7234%",
          ...screenMask("/devices/ipad-pro-11-screen-mask.png")
        }}
      />
      <ThemedImage
        light="/devices/ipad-pro-11-silver.webp"
        dark="/devices/ipad-pro-11-space-black.webp"
        alt=""
        width={1320}
        height={940}
        eager={eager}
        className={BEZEL}
      />
    </div>
  )
}

export const DEVICE_SHADOW = "drop-shadow-[0_30px_40px_rgba(0,0,0,0.3)]"

export function DeviceTrio({
  mac,
  ipad,
  iphone,
  eager
}: {
  mac: Shot
  ipad: Shot
  iphone: Shot
  eager?: boolean
}) {
  return (
    <div className="landing-noselect relative pr-[10%] pb-[4%] md:p-0">
      <div className="relative md:ml-[10.01%] md:w-[62.91%]">
        <MacBookPro {...mac} eager={eager} />
      </div>
      <img
        draggable={false}
        src="/devices/mac-studio.webp"
        alt="Mac Studio"
        width={856}
        height={461}
        loading={eager ? "eager" : "lazy"}
        className="absolute bottom-0 left-0 z-10 hidden h-auto w-[29.39%] translate-y-[16.7%] md:block"
      />
      <div
        className={`absolute bottom-0 left-[48.95%] z-10 hidden w-[44.01%] md:block ${DEVICE_SHADOW}`}
      >
        <IPadPro {...ipad} eager={eager} />
      </div>
      <div className="absolute right-0 bottom-0 z-20 w-[22%] md:w-[13.86%]">
        <IPhonePro {...iphone} eager={eager} className={DEVICE_SHADOW} />
      </div>
    </div>
  )
}
