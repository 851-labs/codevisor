export const sidebarFigure = { slot: 40, overhang: 1.2 }

export const circleAvatar = {
  size: 44,
  imageScale: 1.32,
  drop: 0.12,
  fill: ["#f7f7f7", "#e0e0e0"] as const
}

export const displayScales: ReadonlyArray<number> = [1, 2, 3]

export const figureSide = sidebarFigure.slot * sidebarFigure.overhang
