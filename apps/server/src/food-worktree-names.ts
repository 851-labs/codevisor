// Development worktrees use a visibly different namespace from production's
// single food words. The curated phrases stay recognizable in window titles,
// while the variants give development more than 500 memorable choices before
// the four-digit uniqueness suffix is applied.
const foodNameBases = [
  "apple-pie",
  "avocado-toast",
  "bacon-biscuits",
  "baked-ziti",
  "banana-bread",
  "barbecue-ribs",
  "beef-bourguignon",
  "beef-tacos",
  "beignets",
  "berry-cobbler",
  "biryani",
  "biscuits-gravy",
  "black-bean-burger",
  "blueberry-pancakes",
  "breakfast-burrito",
  "brisket",
  "broccoli-cheddar-soup",
  "brownie-sundae",
  "buffalo-wings",
  "burrata-salad",
  "butter-chicken",
  "caesar-salad",
  "cannoli",
  "caramel-popcorn",
  "carbonara",
  "carrot-cake",
  "cheese-curds",
  "cheeseburger",
  "chicken-fingers",
  "chicken-noodle-soup",
  "chicken-parmesan",
  "chicken-pot-pie",
  "chicken-tacos",
  "chili-con-carne",
  "chocolate-chip-cookies",
  "churros",
  "cinnamon-rolls",
  "clam-chowder",
  "cobb-salad",
  "coconut-curry",
  "cornbread",
  "crab-cakes",
  "crepes",
  "croque-monsieur",
  "cuban-sandwich",
  "deviled-eggs",
  "dumplings",
  "eggplant-parmesan",
  "enchiladas",
  "falafel",
  "fish-chips",
  "focaccia",
  "french-onion-soup",
  "fried-chicken",
  "fried-rice",
  "fruit-tart",
  "garlic-bread",
  "gingerbread",
  "gnocchi",
  "grilled-cheese",
  "gumbo",
  "gyros",
  "hash-browns",
  "hot-pot",
  "huevos-rancheros",
  "ice-cream-sandwich",
  "jambalaya",
  "kebabs",
  "key-lime-pie",
  "lasagna",
  "lemon-bars",
  "lobster-roll",
  "mac-cheese",
  "mango-sticky-rice",
  "meatball-sub",
  "meatloaf",
  "mushroom-risotto",
  "nachos",
  "oatmeal-cookies",
  "onion-rings",
  "pad-thai",
  "paella",
  "pancakes",
  "pasta-primavera",
  "peach-cobbler",
  "peanut-butter-cookies",
  "pecan-pie",
  "pepperoni-pizza",
  "pesto-pasta",
  "philly-cheesesteak",
  "pho",
  "pierogi",
  "poke-bowl",
  "pork-buns",
  "potato-salad",
  "potstickers",
  "pulled-pork",
  "pumpkin-pie",
  "quesadilla",
  "ramen",
  "ratatouille",
  "red-velvet-cake",
  "reuben-sandwich",
  "roast-beef",
  "roasted-potatoes",
  "salmon-teriyaki",
  "samosas",
  "sausage-rolls",
  "shawarma",
  "shepherds-pie",
  "shrimp-grits",
  "shrimp-tacos",
  "sloppy-joes",
  "snickerdoodles",
  "spaghetti-meatballs",
  "spanakopita",
  "spring-rolls",
  "steak-frites",
  "strawberry-shortcake",
  "stuffed-peppers",
  "sushi-rolls",
  "sweet-potato-fries",
  "tamales",
  "teriyaki-chicken",
  "tiramisu",
  "tomato-bisque",
  "tuna-melt",
  "turkey-club",
  "vanilla-cupcakes",
  "veggie-burger",
  "waffles",
  "wonton-soup",
  "zucchini-bread"
] as const

const foodNameStyles = ["", "crispy", "smoky", "spicy"] as const

export const foodWorktreeNames: ReadonlyArray<string> = foodNameStyles.flatMap((style) =>
  foodNameBases.map((base) => (style === "" ? base : `${style}-${base}`))
)

const randomFoodIndex = (random: () => number): number =>
  Math.min(foodWorktreeNames.length - 1, Math.floor(random() * foodWorktreeNames.length))

const defaultFourDigits = (): string => String(Math.floor(Math.random() * 10_000)).padStart(4, "0")

/// Development names always use a food base plus four digits. Random retries
/// handle normal allocation; the bounded scan guarantees progress even under
/// a deterministic or adversarial random source.
export const availableDevelopmentWorktreeName = (
  existing: ReadonlySet<string>,
  random: () => number = Math.random,
  randomDigits: () => string = defaultFourDigits
): string => {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const base = foodWorktreeNames[randomFoodIndex(random)]!
    const digits = randomDigits().padStart(4, "0").slice(-4)
    const candidate = `${base}-${digits}`
    if (!existing.has(candidate)) return candidate
  }

  const baseOffset = randomFoodIndex(random)
  const digitOffset = Number.parseInt(randomDigits(), 10) % 10_000 || 0
  for (let baseStep = 0; baseStep < foodWorktreeNames.length; baseStep += 1) {
    const base = foodWorktreeNames[(baseOffset + baseStep) % foodWorktreeNames.length]!
    for (let digitStep = 0; digitStep < 10_000; digitStep += 1) {
      const digits = String((digitOffset + digitStep) % 10_000).padStart(4, "0")
      const candidate = `${base}-${digits}`
      if (!existing.has(candidate)) return candidate
    }
  }
  /* v8 ignore next -- reaching this requires all 5M+ generated names to exist simultaneously. */
  throw new Error("Unable to allocate a unique development worktree name")
}
