//  The famous-people pool the server also draws worktree slugs from
//  (deceased STEM pioneers): workspace names prefill from here, and when a
//  workspace starts in a new worktree the worktree takes the same name.

import Foundation

enum WorkspaceNameGenerator {
    static let names: [String] = [
        "abrikosov", "adrian", "akasaki", "al-biruni", "al-khwarizmi", "al-nafis", "al-zahrawi", "alder",
        "alferov", "alfven", "alhazen", "allais", "altman", "alvarez", "ampere", "anderson",
        "anfinsen", "anning", "appleton", "archimedes", "aristarchus", "arrhenius", "arrow", "aryabhata",
        "ashkin", "aston", "atanasoff", "avicenna", "axelrod", "babbage", "bacon", "baird",
        "baltimore", "banting", "barany", "bardeen", "barkla", "barton", "basov", "bayes",
        "beadle", "becker", "becquerel", "benacerraf", "berg", "bergius", "bergstrom", "bernoulli",
        "berry", "bessel", "bethe", "bhabha", "bishop", "black", "blackett", "blobel",
        "bloch", "bloembergen", "blumberg", "boas", "bohr", "boltzmann", "boole", "bordet",
        "born", "bosch", "bose", "bothe", "bovet", "boyer", "boyle", "bragg",
        "brahe", "brahmagupta", "brattain", "braun", "brenner", "bridgman", "brockhouse", "brown",
        "brus", "buchanan", "buchner", "burnet", "butenandt", "cajal", "calvin", "cantor",
        "cardano", "carlsson", "carrel", "carson", "cavendish", "celsius", "chadwick", "chain",
        "chamberlain", "charpak", "chauvin", "cherenkov", "claude", "clausius", "coase", "cockcroft",
        "cohen", "compton", "cooper", "copernicus", "cori", "cormack", "cornforth", "coulomb",
        "cournand", "cram", "crick", "cronin", "crutzen", "curie", "curl", "dale",
        "dalen", "dalton", "dam", "darwin", "dausset", "davis", "davisson", "de-broglie",
        "de-duve", "de-gennes", "de-hevesy", "debreu", "debye", "dehmelt", "delbruck", "descartes",
        "diels", "dirac", "doisy", "domagk", "du-vigneaud", "dulbecco", "eccles", "edelman",
        "edison", "edwards", "ehrlich", "eiffel", "eigen", "eijkman", "einstein", "einthoven",
        "elion", "enders", "englert", "erlanger", "ernst", "euclid", "euler", "faraday",
        "fenn", "fermat", "fermi", "feynman", "fibiger", "finsen", "fischer", "fitch",
        "fleming", "florey", "flory", "fogel", "forssmann", "fourier", "fowler", "franck",
        "frank", "franklin", "friedman", "frisch", "fukui", "furchgott", "gabor", "gajdusek",
        "galilei", "galvani", "gasser", "gauss", "gell-mann", "giacconi", "giaever", "giauque",
        "gilman", "ginzburg", "glaser", "glauber", "godel", "golgi", "goodenough", "granger",
        "granit", "greengard", "grignard", "grubbs", "grunberg", "guillaume", "guillemin", "gullstrand",
        "gurdon", "haavelmo", "haber", "haeckel", "hahn", "halley", "harden", "harsanyi",
        "hartline", "harvey", "hassel", "hauptman", "haworth", "heck", "heisenberg", "hench",
        "heron", "herschel", "hershey", "hertz", "herzberg", "hess", "hewish", "heymans",
        "heyrovsky", "hicks", "higgs", "hilbert", "hill", "hinshelwood", "hipparchus", "hippocrates",
        "hitchings", "hodgkin", "hofstadter", "holley", "hooke", "hopkins", "hopper", "hounsfield",
        "houssay", "hubble", "hubel", "huggins", "hurwicz", "huxley", "huygens", "ingenhousz",
        "jackson", "jacob", "jenner", "jensen", "jerne", "johnson", "joliot", "joliot-curie",
        "joule", "kahneman", "kantorovich", "kao", "kapitsa", "karle", "karplus", "karrer",
        "kastler", "katz", "kendall", "kendrew", "kepler", "khayyam", "khorana", "kilby",
        "kirchhoff", "klein", "klug", "knowles", "koch", "kocher", "kohler", "kohn",
        "koopmans", "kornberg", "korolev", "koshiba", "kossel", "kovalevskaya", "krebs", "kroemer",
        "krogh", "kroto", "kuhn", "kusch", "kuznets", "lamb", "landau", "landsteiner",
        "langmuir", "lauterbur", "laveran", "lavoisier", "lawrence", "leavitt", "leclerc", "lederberg",
        "lederman", "lee", "leggett", "lehmann", "leibniz", "leloir", "lemaitre", "lenard",
        "leontief", "lewis", "libby", "linnaeus", "lipmann", "lippmann", "lipscomb", "lister",
        "loewi", "lomonosov", "lorentz", "lorenz", "lovelace", "lucas", "luria", "lwoff",
        "lyell", "lynen", "macdiarmid", "macleod", "mandelbrot", "mansfield", "marconi", "markowitz",
        "martin", "maskawa", "maxwell", "mcclintock", "mcmillan", "meade", "mechnikov", "medawar",
        "meitner", "mendel", "mendeleev", "merrifield", "meyerhof", "michelson", "milankovic", "miller",
        "millikan", "milstein", "minot", "mirrlees", "mitchell", "modigliani", "moissan", "molina",
        "moniz", "monod", "montagnier", "moore", "morgan", "mortensen", "mossbauer", "mott",
        "mottelson", "muller", "mulliken", "mullis", "mundell", "murad", "murphy", "murray",
        "myrdal", "nambu", "napier", "nash", "nathans", "natta", "neel", "negishi",
        "nernst", "newton", "nicolle", "nightingale", "nirenberg", "noether", "norrish", "north",
        "northrop", "ochoa", "ohlin", "olah", "onsager", "ostrom", "ostwald", "palade",
        "pascal", "paul", "pauli", "pauling", "pavlov", "pedersen", "penzias", "perl",
        "perrin", "perutz", "phelps", "planck", "poincare", "pople", "porter", "powell",
        "pregl", "prelog", "prescott", "priestley", "prigogine", "prokhorov", "purcell", "rabi",
        "rainwater", "raman", "ramanujan", "ramsay", "ramsey", "rayleigh", "reichstein", "reines",
        "richards", "richardson", "richet", "richter", "robbins", "robinson", "rodbell", "rohrer",
        "rontgen", "rose", "ross", "rous", "rowland", "rubin", "ruska", "rutherford",
        "ruzicka", "ryle", "sabatier", "sagan", "salam", "samuelson", "samuelsson", "sanger",
        "sarabhai", "schally", "schawlow", "schelling", "schrieffer", "schrodinger", "schultz", "schwartz",
        "schwinger", "seaborg", "segre", "selten", "semenov", "shapley", "sherrington", "shimomura",
        "shockley", "shull", "siegbahn", "simon", "sims", "sina", "skou", "smalley",
        "smith", "smithies", "smoot", "snell", "snow", "soddy", "solow", "spemann",
        "sperry", "stanley", "stark", "staudinger", "stein", "steinberger", "steinman", "steitz",
        "stern", "stigler", "stoddart", "stone", "sulston", "sumner", "sutherland", "svedberg",
        "synge", "tamm", "tatum", "taube", "taylor", "telkes", "temin", "tharp",
        "theiler", "theorell", "thomas", "thomson", "thouless", "tinbergen", "tiselius", "tobin",
        "todd", "tomonaga", "torricelli", "townes", "tsien", "turing", "urey", "van-der-meer",
        "van-t-hoff", "van-vleck", "vane", "vaughan", "veltman", "vickrey", "vinci", "virtanen",
        "von-baeyer", "von-behring", "von-bekesy", "von-euler", "von-frisch", "von-hayek", "von-laue", "waksman",
        "wald", "wallach", "walton", "warburg", "warren", "watson", "watt", "wegener",
        "weinberg", "weiss", "weller", "werner", "whipple", "wieland", "wien", "wigner",
        "wilkins", "wilkinson", "willstatter", "wilson", "windaus", "wittig", "wohler", "woodward",
        "wu", "yalow", "yang", "young", "yukawa", "zeeman", "zernike", "zewail",
        "ziegler", "zsigmondy", "zur-hausen", "zuse",
    ]

    /// A random name not already taken by an existing workspace.
    static func next(excluding taken: Set<String>) -> String {
        let available = names.filter { !taken.contains($0) }
        return (available.randomElement() ?? names.randomElement()) ?? "workspace"
    }

    /// A workspace name as a worktree-safe slug (git-branch-safe, path-safe;
    /// the worktree created for a workspace takes the workspace's name).
    static func slug(from name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "workspace" : String(collapsed.prefix(40))
    }
}
