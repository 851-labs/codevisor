import type { CSSProperties } from "react"

export function ThemedImage({
  light,
  dark,
  alt,
  width,
  height,
  eager = false,
  className = "",
  style
}: {
  light: string
  dark: string
  alt: string
  width?: number
  height?: number
  eager?: boolean
  className?: string
  style?: CSSProperties
}) {
  const loading = eager ? "eager" : "lazy"
  return (
    <>
      <img
        draggable={false}
        src={light}
        alt={alt}
        width={width}
        height={height}
        loading={loading}
        className={`landing-light ${className}`}
        style={style}
      />
      <img
        draggable={false}
        src={dark}
        alt={alt}
        width={width}
        height={height}
        loading={loading}
        className={`landing-dark ${className}`}
        style={style}
      />
    </>
  )
}
