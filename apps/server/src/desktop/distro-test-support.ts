const retry = "Trying again in 10 seconds."
const dnfLoop = `for try in $(seq 60); do seen=$(cat /var/log/dnf5.log 2>/dev/null | wc -l); dnf install -y --setopt=install_weak_deps=False "$@" && exit 0; tail -n +"$((seen + 1))" /var/log/dnf5.log 2>/dev/null | grep -q "transaction lock" || exit 1; echo "Something else is installing packages. ${retry}"; sleep 10; done; exit 1`
const pacmanLoop = `for try in $(seq 60); do { ls /var/lib/pacman/sync/*.db >/dev/null 2>&1 || pacman -Sy --noconfirm; } && pacman -S --needed --noconfirm "$@" && exit 0; [ -e /var/lib/pacman/db.lck ] || { echo "If packages were not found, the package lists here are old. Run pacman -Syu, then set the desktop up again."; exit 1; }; grep -qsx pacman /proc/[0-9]*/comm || { echo "/var/lib/pacman/db.lck exists but no pacman is running. If another package manager is at work, set the desktop up again when it is done. Otherwise the lock was left behind: remove it, then set the desktop up again."; exit 1; }; echo "Another pacman is running. ${retry}"; sleep 10; done; exit 1`
const xfce = "xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfce4-terminal xfconf"
const dnfInstall = `sh -c ${dnfLoop} sh tigervnc-server-minimal ${xfce} dbus-daemon xclip python3 dejavu-sans-fonts adwaita-icon-theme`
const pacmanInstall = `sh -c ${pacmanLoop} sh tigervnc ${xfce} dbus xclip python ttf-dejavu adwaita-icon-theme`
const zypperScript = `rpm -q xfce4-panel-branding-openSUSE >/dev/null 2>&1 || set -- "$@" xfce4-panel-branding-upstream; env ZYPP_LOCK_TIMEOUT=600 zypper --non-interactive --ignore-unknown install --no-recommends "$@"; code=$?; case $code in 102|103|107) exit 0 ;; 106) for program in Xvnc startxfce4 xfconf-query dbus-run-session xclip python3; do command -v "$program" >/dev/null || { echo "zypper skipped a repository it could not refresh, so not everything was installed. Check the repositories with: zypper refresh"; exit $code; }; done; exit 0 ;; esac; exit $code`
const zypperInstall = `sh -c ${zypperScript} sh xorg-x11-Xvnc ${xfce} dbus-1 dbus-1-daemon xclip python3 dejavu-fonts adwaita-icon-theme`

const osRelease = (text: string) => ({ "/etc/os-release": text })

export interface Distro {
  readonly name: string
  readonly files: Record<string, string>
  readonly manager: string
  readonly program: string
  readonly megabytes: number
  readonly installs: ReadonlyArray<string>
}

export const READ_ONLY_USR = {
  "/proc/mounts": [
    "composefs / overlay ro,seclabel,relatime 0 0",
    "/dev/vda3 /usr btrfs ro,seclabel,relatime,compress=zstd:1 0 0",
    "/dev/vda3 /var btrfs rw,seclabel,relatime 0 0",
    ""
  ].join("\n")
}

export const ALPINE = osRelease('PRETTY_NAME="Alpine Linux v3.22"\nID=alpine\n')

export const DISTROS: ReadonlyArray<Distro> = [
  {
    name: "Fedora Linux 45 (Server Edition)",
    files: osRelease('PRETTY_NAME="Fedora Linux 45 (Server Edition)"\nID=fedora\n'),
    manager: "dnf",
    program: "dnf",
    megabytes: 450,
    installs: [dnfInstall]
  },
  {
    name: "Fedora Linux Asahi Remix 42 (Forty Two)",
    files: osRelease(
      'PRETTY_NAME="Fedora Linux Asahi Remix 42 (Forty Two)"\nID=fedora-asahi-remix\nID_LIKE=fedora\n'
    ),
    manager: "dnf",
    program: "dnf",
    megabytes: 450,
    installs: [dnfInstall]
  },
  {
    name: "Ultramarine Linux 42",
    files: osRelease('PRETTY_NAME="Ultramarine Linux 42"\nID=ultramarine\nID_LIKE=fedora\n'),
    manager: "dnf",
    program: "dnf",
    megabytes: 450,
    installs: [dnfInstall]
  },
  {
    name: "Arch Linux",
    files: osRelease('PRETTY_NAME="Arch Linux"\nID=arch\n'),
    manager: "pacman",
    program: "pacman",
    megabytes: 980,
    installs: [pacmanInstall]
  },
  {
    name: "Arch Linux ARM",
    files: osRelease('PRETTY_NAME="Arch Linux ARM"\nID=archarm\nID_LIKE=arch\n'),
    manager: "pacman",
    program: "pacman",
    megabytes: 980,
    installs: [pacmanInstall]
  },
  {
    name: "openSUSE Tumbleweed",
    files: osRelease(
      'PRETTY_NAME="openSUSE Tumbleweed"\nID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\n'
    ),
    manager: "zypper",
    program: "zypper",
    megabytes: 740,
    installs: [zypperInstall]
  },
  {
    name: "openSUSE Leap 15.6",
    files: osRelease(
      'PRETTY_NAME="openSUSE Leap 15.6"\nID="opensuse-leap"\nID_LIKE="suse opensuse"\n'
    ),
    manager: "zypper",
    program: "zypper",
    megabytes: 740,
    installs: [zypperInstall]
  }
]

export const UNSERVED = [
  {
    name: "Rocky Linux, whose own repositories have no Xfce",
    files: osRelease('PRETTY_NAME="Rocky Linux 9.5"\nID="rocky"\nID_LIKE="rhel centos fedora"\n'),
    programs: ["dnf", "sudo"]
  },
  {
    name: "Red Hat Enterprise Linux, which is like Fedora but has no Xfce of its own",
    files: osRelease(
      'PRETTY_NAME="Red Hat Enterprise Linux 9.5 (Plow)"\nID="rhel"\nID_LIKE="fedora"\n'
    ),
    programs: ["dnf", "sudo"]
  },
  {
    name: "CentOS Stream",
    files: osRelease('PRETTY_NAME="CentOS Stream 9"\nID="centos"\nID_LIKE="rhel fedora"\n'),
    programs: ["dnf", "sudo"]
  },
  {
    name: "Amazon Linux, which is like Fedora but has no Xfce of its own",
    files: osRelease('PRETTY_NAME="Amazon Linux 2023"\nID="amzn"\nID_LIKE="fedora"\n'),
    programs: ["dnf", "sudo"]
  },
  {
    name: "Oracle Linux",
    files: osRelease('PRETTY_NAME="Oracle Linux Server 9.5"\nID="ol"\nID_LIKE="fedora"\n'),
    programs: ["dnf", "sudo"]
  },
  {
    name: "SUSE Linux Enterprise, whose own repositories have no Xfce",
    files: osRelease(
      'PRETTY_NAME="SUSE Linux Enterprise Server 15 SP6"\nID="sles"\nID_LIKE="suse"\n'
    ),
    programs: ["zypper", "sudo"]
  },
  {
    name: "Fedora without dnf",
    files: osRelease('PRETTY_NAME="Fedora Linux 45"\nID=fedora\n'),
    programs: ["rpm-ostree", "sudo"]
  },
  {
    name: "a Fedora whose system files are read-only (Silverblue)",
    files: {
      ...osRelease('PRETTY_NAME="Fedora Linux 45 (Silverblue)"\nID=fedora\n'),
      ...READ_ONLY_USR
    },
    programs: ["dnf", "sudo"]
  },
  { name: "Alpine", files: ALPINE, programs: ["apk", "sudo"] }
]
