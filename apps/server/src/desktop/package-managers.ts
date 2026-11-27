import type { RootCommand } from "./old-desktop.js"

export type PackageManager = "apt" | "dnf" | "pacman" | "zypper"

export const DESKTOP_PROGRAMS = [
  "Xvnc",
  "startxfce4",
  "xfconf-query",
  "dbus-run-session",
  "xclip",
  "python3"
] as const

export interface OsRelease {
  readonly name: string
  readonly id: string
  readonly ids: ReadonlyArray<string>
}

export interface PackageFamily {
  readonly manager: PackageManager
  readonly program: string
  readonly megabytes: number
  readonly serves: (release: OsRelease) => boolean
  readonly commands: ReadonlyArray<RootCommand>
}

const lockWaitSeconds = 600
const retrySeconds = 10
const tries = lockWaitSeconds / retrySeconds
const again = `Trying again in ${retrySeconds} seconds.`

const aptPackages = [
  "tigervnc-standalone-server",
  "tigervnc-common",
  "xfce4",
  "xfce4-terminal",
  "dbus-x11",
  "xclip",
  "python3",
  "fonts-dejavu-core",
  "adwaita-icon-theme"
]
const dnfPackages = [
  "tigervnc-server-minimal",
  "xfce4-session",
  "xfwm4",
  "xfce4-panel",
  "xfdesktop",
  "xfce4-settings",
  "xfce4-terminal",
  "xfconf",
  "dbus-daemon",
  "xclip",
  "python3",
  "dejavu-sans-fonts",
  "adwaita-icon-theme"
]
const pacmanPackages = [
  "tigervnc",
  "xfce4-session",
  "xfwm4",
  "xfce4-panel",
  "xfdesktop",
  "xfce4-settings",
  "xfce4-terminal",
  "xfconf",
  "dbus",
  "xclip",
  "python",
  "ttf-dejavu",
  "adwaita-icon-theme"
]
const zypperPackages = [
  "xorg-x11-Xvnc",
  "xfce4-session",
  "xfwm4",
  "xfce4-panel",
  "xfdesktop",
  "xfce4-settings",
  "xfce4-terminal",
  "xfconf",
  "dbus-1",
  "dbus-1-daemon",
  "xclip",
  "python3",
  "dejavu-fonts",
  "adwaita-icon-theme"
]

const aptFamily = new Set(["debian", "ubuntu"])
const withoutXfceOfTheirOwn = new Set(["rhel", "centos", "ol", "amzn"])
const aptQuietly = ["env", "DEBIAN_FRONTEND=noninteractive"]
const aptUpdateUntilTheListsLockIsFree = `for try in $(seq ${tries}); do out=$(apt-get update -q 2>&1) && exit 0; echo "$out"; echo "$out" | grep -q "Could not get lock" || exit 1; sleep ${retrySeconds}; done; exit 1`

const dnfLog = "/var/log/dnf5.log"
const dnfUntilTheRpmLockIsFree = `for try in $(seq ${tries}); do seen=$(cat ${dnfLog} 2>/dev/null | wc -l); dnf install -y --setopt=install_weak_deps=False "$@" && exit 0; tail -n +"$((seen + 1))" ${dnfLog} 2>/dev/null | grep -q "transaction lock" || exit 1; echo "Something else is installing packages. ${again}"; sleep ${retrySeconds}; done; exit 1`

const pacmanLock = "/var/lib/pacman/db.lck"
const pacmanListsAreOld =
  "If packages were not found, the package lists here are old. Run pacman -Syu, then set the desktop up again."
const pacmanLockWasLeftBehind = `${pacmanLock} exists but no pacman is running. If another package manager is at work, set the desktop up again when it is done. Otherwise the lock was left behind: remove it, then set the desktop up again.`
const pacmanUntilItsLockIsFree = `for try in $(seq ${tries}); do { ls /var/lib/pacman/sync/*.db >/dev/null 2>&1 || pacman -Sy --noconfirm; } && pacman -S --needed --noconfirm "$@" && exit 0; [ -e ${pacmanLock} ] || { echo "${pacmanListsAreOld}"; exit 1; }; grep -qsx pacman /proc/[0-9]*/comm || { echo "${pacmanLockWasLeftBehind}"; exit 1; }; echo "Another pacman is running. ${again}"; sleep ${retrySeconds}; done; exit 1`

const zypperInstalledBut = "102|103|107"
const zypperSkippedARepository = "106"
const zypperSkippedAndFellShort =
  "zypper skipped a repository it could not refresh, so not everything was installed. Check the repositories with: zypper refresh"
const zypperWithTheStockPanel = `rpm -q xfce4-panel-branding-openSUSE >/dev/null 2>&1 || set -- "$@" xfce4-panel-branding-upstream; env ZYPP_LOCK_TIMEOUT=${lockWaitSeconds} zypper --non-interactive --ignore-unknown install --no-recommends "$@"; code=$?; case $code in ${zypperInstalledBut}) exit 0 ;; ${zypperSkippedARepository}) for program in ${DESKTOP_PROGRAMS.join(" ")}; do command -v "$program" >/dev/null || { echo "${zypperSkippedAndFellShort}"; exit $code; }; done; exit 0 ;; esac; exit $code`

export const packageFamilies: ReadonlyArray<PackageFamily> = [
  {
    manager: "apt",
    program: "apt-get",
    megabytes: 640,
    serves: (release) => release.ids.some((id) => aptFamily.has(id)),
    commands: [
      [...aptQuietly, "sh", "-c", aptUpdateUntilTheListsLockIsFree],
      [
        ...aptQuietly,
        "apt-get",
        "-o",
        `DPkg::Lock::Timeout=${lockWaitSeconds}`,
        "install",
        "-y",
        "-q",
        "--no-install-recommends",
        ...aptPackages
      ]
    ]
  },
  {
    manager: "dnf",
    program: "dnf",
    megabytes: 450,
    serves: (release) =>
      release.ids.includes("fedora") && !release.ids.some((id) => withoutXfceOfTheirOwn.has(id)),
    commands: [["sh", "-c", dnfUntilTheRpmLockIsFree, "sh", ...dnfPackages]]
  },
  {
    manager: "pacman",
    program: "pacman",
    megabytes: 980,
    serves: (release) => release.ids.includes("arch"),
    commands: [["sh", "-c", pacmanUntilItsLockIsFree, "sh", ...pacmanPackages]]
  },
  {
    manager: "zypper",
    program: "zypper",
    megabytes: 740,
    serves: (release) => release.ids.includes("opensuse"),
    commands: [["sh", "-c", zypperWithTheStockPanel, "sh", ...zypperPackages]]
  }
]
