import { createFileRoute } from "@tanstack/react-router"

import { Home } from "../landing/home"

export const Route = createFileRoute("/")({
  component: Home
})
