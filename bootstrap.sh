#!/usr/bin/env bash
set -euo pipefail

LOG="/var/log/bootstrap.log"

# -------------------------
# Flatpak app IDs (Flathub)
# -------------------------
FLATPAK_APPS=(
  org.mozilla.firefox
  org.kde.okular
  com.github.tchx84.Flatseal
  org.telegram.desktop
  org.libreoffice.LibreOffice
  org.videolan.VLC
  com.discordapp.Discord
  com.google.Chrome
  org.onlyoffice.desktopeditors
  md.obsidian.Obsidian
)

MASTER_PDF_IDS=(
  net.code_industry.MasterPDFEditor
  net.codeindustry.MasterPDFEditor
)

APT_PACKAGES=(
  ca-certificates
  curl
  gnupg
  software-properties-common
  flatpak
  gnome-software-plugin-flatpak
  gnome-sushi
)

log() { echo -e "\n==> $*\n"; }

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
  fi
}

get_desktop_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
  else
    log "WARNING: Could not determine desktop user. Skipping gsettings."
    echo ""
  fi
}

apt_update() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends "$@"
}

block_snapd_reinstall() {
  log "Blocking snapd reinstall"
  cat >/etc/apt/preferences.d/no-snapd.pref <<'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
}

remove_snap() {
  log "Removing snap"

  if command -v snap >/dev/null 2>&1; then
    mapfile -t snaps < <(snap list 2>/dev/null | awk 'NR>1 {print $1}' || true)
    for s in "${snaps[@]:-}"; do
      snap remove --purge "$s" || true
    done
  fi

  apt_update
  apt-get purge -y snapd gnome-software-plugin-snap || true
  apt-get autoremove -y || true

  rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd ~/snap 2>/dev/null || true

  block_snapd_reinstall
}

install_flatpak_and_flathub() {
  log "Installing Flatpak + Flathub"
  apt_update
  apt_install "${APT_PACKAGES[@]}"

  if ! flatpak remotes --columns=name 2>/dev/null | grep -qx "flathub"; then
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  fi
}

flatpak_app_exists() {
  flatpak remote-info flathub "$1" >/dev/null 2>&1
}

install_master_pdf_editor() {
  log "Installing Master PDF Editor"
  for id in "${MASTER_PDF_IDS[@]}"; do
    if flatpak_app_exists "$id"; then
      flatpak install -y --noninteractive flathub "$id"
      return
    fi
  done
  log "Master PDF Editor not found under known IDs."
}

install_flatpaks() {
  log "Installing Flatpaks"
  flatpak install -y --noninteractive flathub "${FLATPAK_APPS[@]}"
  install_master_pdf_editor
}

enable_nautilus_hover_open() {
  local user
  user=$(get_desktop_user)

  if [[ -n "$user" ]]; then
    log "Enabling Nautilus open-folder-on-dnd-hover for user: $user"
    sudo -u "$user" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$user")/bus" \
      gsettings set org.gnome.nautilus.preferences open-folder-on-dnd-hover true \
      || log "Could not apply gsettings (user may not be logged into GNOME)."
  fi
}

install_vocalinux() {
  log "Installing Vocalinux (non-interactive)"
  curl -fsSL https://raw.githubusercontent.com/jatinkrmalik/vocalinux/v0.6.2-beta/install.sh -o /tmp/vl.sh
  chmod +x /tmp/vl.sh

  if bash /tmp/vl.sh --help 2>&1 | grep -q -- "--yes"; then
    bash /tmp/vl.sh --yes || log "Vocalinux installer exited non-zero."
  else
    yes | bash /tmp/vl.sh || log "Vocalinux installer exited non-zero."
  fi
}

cleanup() {
  log "Cleanup"
  apt-get autoremove -y || true
  apt-get autoclean -y || true
  flatpak uninstall -y --unused || true
}

main() {
  require_root
  exec > >(tee -a "$LOG") 2>&1

  log "Starting bootstrap on $(hostname) - Ubuntu Desktop 24.04"

  remove_snap
  install_flatpak_and_flathub
  install_flatpaks
  enable_nautilus_hover_open
  install_vocalinux
  cleanup

  log "Bootstrap complete."
}

main "$@"
