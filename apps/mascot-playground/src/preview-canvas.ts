import { circleAvatar, figureSide } from "./app-sizes.js"
import { svgImage } from "./raster.js"

export type PreviewDrawer = (canvas: HTMLCanvasElement, svg: string, scale: number) => Promise<void>

export const drawFigure: PreviewDrawer = async (canvas, svg, scale) => {
  const pixels = figureSide * scale
  const image = await svgImage(svg, pixels)
  const ctx = sizedContext(canvas, pixels)
  ctx?.drawImage(image, 0, 0)
}

export const drawAvatar: PreviewDrawer = async (canvas, svg, scale) => {
  const pixels = circleAvatar.size * scale
  const imageSide = pixels * circleAvatar.imageScale
  const image = await svgImage(svg, imageSide)
  const ctx = sizedContext(canvas, pixels)
  if (!ctx) return

  clipToCircle(ctx, pixels)
  ctx.fillStyle = avatarFill(ctx, pixels)
  ctx.fillRect(0, 0, pixels, pixels)
  const inset = (pixels - imageSide) / 2
  ctx.drawImage(image, inset, inset + pixels * circleAvatar.drop, imageSide, imageSide)
}

function sizedContext(canvas: HTMLCanvasElement, pixels: number): CanvasRenderingContext2D | null {
  canvas.width = pixels
  canvas.height = pixels
  return canvas.getContext("2d")
}

function clipToCircle(ctx: CanvasRenderingContext2D, pixels: number): void {
  ctx.beginPath()
  ctx.arc(pixels / 2, pixels / 2, pixels / 2, 0, Math.PI * 2)
  ctx.clip()
}

function avatarFill(ctx: CanvasRenderingContext2D, pixels: number): CanvasGradient {
  const gradient = ctx.createLinearGradient(0, 0, 0, pixels)
  gradient.addColorStop(0, circleAvatar.fill[0])
  gradient.addColorStop(1, circleAvatar.fill[1])
  return gradient
}
