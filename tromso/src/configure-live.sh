#!/usr/bin/bash
# Live-environment setup for the Aurora Tromso ISO installer image.
#
# Runs inside the final Tromso container stage with:
#   --cap-add sys_admin --security-opt label=disable
#
# At this point the initramfs has already been replaced (by the Debian
# initramfs-builder stage) with a dmsquash-live capable one.  This script
# handles the runtime live-environment: user, SDDM autologin, tuna-installer
# configuration + autostart, and KDE environment setup.

set -exo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── VERSION_ID ────────────────────────────────────────────────────────────────
if grep -q '^VERSION_ID=' /usr/lib/os-release 2>/dev/null; then
    sed -i 's/^VERSION_ID=.*/VERSION_ID=latest/' /usr/lib/os-release
else
    echo 'VERSION_ID=latest' >> /usr/lib/os-release
fi

# ── Live user ─────────────────────────────────────────────────────────────────
useradd --create-home --uid 1000 --user-group \
    --comment "Live User" liveuser || true
passwd --delete liveuser

if [[ "${DEBUG:-0}" == "1" ]]; then
    echo "liveuser:live" | chpasswd
    passwd --unlock root
    echo "root:root" | chpasswd

    mkdir -p /etc/systemd/system-preset
    echo "enable sshd.service" > /etc/systemd/system-preset/90-live-debug.preset
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /usr/lib/systemd/system/sshd.service \
        /etc/systemd/system/multi-user.target.wants/sshd.service

    # Generate host keys at image build time so sshd starts without ExecStartPre
    ssh-keygen -A

    # Remove unsupported options from the base sshd_config
    sed -i '/^GSSAPIAuthentication/d' /etc/ssh/sshd_config

    cat >> /etc/ssh/sshd_config << 'SSHEOF'
PermitEmptyPasswords no
PasswordAuthentication yes
PermitRootLogin yes
PerSourcePenalties no
SSHEOF

    # Drop-in to keep host keys if /etc/ssh gets overmounted
    mkdir -p /etc/systemd/system/sshd.service.d
    cat > /etc/systemd/system/sshd.service.d/keygen.conf << 'DROPEOF'
[Service]
ExecStartPre=-/usr/bin/ssh-keygen -A
DROPEOF

    mkdir -p /etc/firewalld/zones
    cat > /etc/firewalld/zones/public.xml << 'FWEOF'
<?xml version="1.0" encoding="utf-8"?>
<zone>
  <short>Public</short>
  <service name="ssh"/>
  <service name="mdns"/>
  <service name="dhcpv6-client"/>
</zone>
FWEOF

    cat > /usr/lib/systemd/system/debug-ssh-banner.service << 'BANNEREOF'
[Unit]
Description=Print SSH connection info to serial console
After=sshd.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  IP=$(hostname -I | awk "{print \$1}"); \
  echo ""; \
  echo "========================================"; \
  echo " DEBUG SSH READY"; \
  echo " ssh liveuser@${IP:-<no-ip>}  (password: live)"; \
  echo " ssh root@${IP:-<no-ip>}      (password: root)"; \
  echo "========================================"; \
  echo ""'
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
BANNEREOF
    systemctl enable debug-ssh-banner.service
fi

# Passwordless sudo for liveuser
echo 'liveuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/liveuser
chmod 0440 /etc/sudoers.d/liveuser

# ── KDE environment setup ─────────────────────────────────────────────────────
# Pre-seed the liveuser's environment.d so all user systemd services get the
# correct Wayland variables when the session starts.
mkdir -p /home/liveuser/.config/environment.d
cat > /home/liveuser/.config/environment.d/00-plasma-wayland.conf << 'ENVEOF'
WAYLAND_DISPLAY=wayland-0
QT_QPA_PLATFORM=wayland
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=KDE
QT_PLUGIN_PATH=/usr/lib/plugins
LIBGL_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/GL/default/lib/dri
GBM_BACKENDS_PATH=/usr/lib/x86_64-linux-gnu/GL/default/lib/gbm
ENVEOF
chown -R liveuser:liveuser /home/liveuser

# Mesa alternatives: activate the GL stack so kwin_wayland can use kms_swrast
# for DRM rendering in virtualised environments (virgl disabled, llvmpipe path).
echo '/usr/lib/x86_64-linux-gnu/GL/default/lib' \
    > /etc/ld.so.conf.d/mesa-alternatives.conf
ldconfig

# kwin_wayland drop-in: unset WAYLAND_DISPLAY so kwin uses DRM directly
# instead of nested Wayland mode (which deadlocks against the SDDM compositor).
# Also sets the Mesa driver paths and kms_swrast override for software rendering.
mkdir -p /usr/lib/systemd/user/plasma-kwin_wayland.service.d
cat > /usr/lib/systemd/user/plasma-kwin_wayland.service.d/live-drm.conf << 'SVCEOF'
[Service]
UnsetEnvironment=WAYLAND_DISPLAY
UnsetEnvironment=QT_QPA_PLATFORM
Environment=LIBGL_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/GL/default/lib/dri
Environment=GBM_BACKENDS_PATH=/usr/lib/x86_64-linux-gnu/GL/default/lib/gbm
Environment=MESA_LOADER_DRIVER_OVERRIDE=kms_swrast
Environment=LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu/GL/default/lib
TimeoutSec=120
SVCEOF

# Per-service drop-ins: ensure all Plasma services get QT_QPA_PLATFORM=wayland
# and a generous startup timeout (software rendering is slow on first boot).
for svc in plasma-ksmserver plasma-kded6 plasma-plasmashell plasma-powerdevil \
            plasma-kaccess plasma-gmenudbusmenuproxy plasma-xembedsniproxy \
            plasma-ksplash plasma-kcminit; do
    mkdir -p /usr/lib/systemd/user/${svc}.service.d
    cat > /usr/lib/systemd/user/${svc}.service.d/live-wayland.conf << 'SVCEOF'
[Service]
Environment=QT_QPA_PLATFORM=wayland
Environment=WAYLAND_DISPLAY=wayland-0
Environment=QT_PLUGIN_PATH=/usr/lib/plugins
TimeoutSec=120
SVCEOF
done

# Disable KDE screen locker by default so the live session stays accessible.
mkdir -p /etc/xdg
cat > /etc/xdg/kscreenlockerrc << 'KSLEOF'
[Daemon]
Autolock=false
LockOnResume=false
Timeout=0
KSLEOF

# ── SDDM autologin ────────────────────────────────────────────────────────────
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf << 'SDDMEOF'
[Autologin]
User=liveuser
Session=plasma
Relogin=false
SDDMEOF

# SDDM autologin PAM service: bypasses password authentication for the live
# session.  pam_permit.so grants auth unconditionally.
cat > /etc/pam.d/sddm-autologin << 'PAMEOF'
auth        required    pam_env.so
auth        required    pam_permit.so
account     required    pam_nologin.so
account     required    pam_unix.so
password    required    pam_deny.so
session     required    pam_loginuid.so
-session    optional    pam_keyinit.so force revoke
-session    optional    pam_systemd.so
session     required    pam_unix.so
session     optional    pam_umask.so silent
PAMEOF

# ── Mask sleep/suspend ────────────────────────────────────────────────────────
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# ── /var/tmp tmpfs ────────────────────────────────────────────────────────────
cat > /usr/lib/systemd/system/var-tmp.mount << 'UNITEOF'
[Unit]
Description=Large tmpfs for /var/tmp in the live environment

[Mount]
What=tmpfs
Where=/var/tmp
Type=tmpfs
Options=size=8G,nr_inodes=1m

[Install]
WantedBy=local-fs.target
UNITEOF
systemctl enable var-tmp.mount

# ── Live-ready marker ─────────────────────────────────────────────────────────
cat > /usr/lib/systemd/system/live-ready.service << 'LREOF'
[Unit]
Description=Live environment ready marker
After=display-manager.service
Wants=display-manager.service

[Service]
Type=oneshot
ExecStart=/bin/echo AURORA_LIVE_READY
StandardOutput=journal+console

[Install]
WantedBy=display-manager.service
LREOF
systemctl enable live-ready.service

mkdir -p /var/fisherman-tmp

# ── Installer configuration ───────────────────────────────────────────────────
mkdir -p /etc/bootc-installer
cp "$SCRIPT_DIR/etc/bootc-installer/images.json" /etc/bootc-installer/images.json
cp "$SCRIPT_DIR/etc/bootc-installer/recipe.json"  /etc/bootc-installer/recipe.json
touch /etc/bootc-installer/live-iso-mode

# ── Installer autostart (KDE variant) ──────────────────────────────────────────
INSTALLER_APP_ID="org.kdeinstaller.Installer"
[[ "${INSTALLER_CHANNEL:-stable}" == "dev" ]] && INSTALLER_APP_ID="org.kdeinstaller.Installer.Devel"

mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/tuna-installer.desktop << DTEOF
[Desktop Entry]
Name=Aurora Installer
Exec=flatpak run --env=VANILLA_CUSTOM_RECIPE=/run/host/etc/bootc-installer/recipe.json ${INSTALLER_APP_ID}
Icon=system-software-install
Terminal=false
Type=Application
X-KDE-autostart-phase=2
DTEOF

mkdir -p /usr/share/applications
cat > /usr/share/applications/aurora-installer.desktop << DTEOF
[Desktop Entry]
Name=Aurora Installer
Comment=Install Aurora to your computer
Exec=flatpak run --env=VANILLA_CUSTOM_RECIPE=/run/host/etc/bootc-installer/recipe.json ${INSTALLER_APP_ID}
Icon=system-software-install
Type=Application
Categories=System;
NoDisplay=false
DTEOF

# ── Polkit for live installer ─────────────────────────────────────────────────
FISHERMAN_BIN=$(find /var/lib/flatpak/app/${INSTALLER_APP_ID} -name fisherman -type f 2>/dev/null | head -1 || true)
if [ -n "$FISHERMAN_BIN" ]; then
    mkdir -p /usr/local/bin
    ln -sf "${FISHERMAN_BIN}" /usr/local/bin/fisherman
    echo "fisherman → ${FISHERMAN_BIN}"
else
    echo "WARNING: fisherman binary not found in flatpak app dir" >&2
fi

mkdir -p /usr/share/polkit-1/actions
cat > /usr/share/polkit-1/actions/org.kdeinstaller.Installer.policy << 'POLICYEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
  "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
  "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <action id="org.tunaos.Installer.install">
    <description>Install an operating system to disk</description>
    <message>Authentication is required to install an operating system</message>
    <icon_name>drive-harddisk</icon_name>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/bin/fisherman</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>
</policyconfig>
POLICYEOF

mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/99-live-installer.rules << 'RULESEOF'
polkit.addRule(function(action, subject) {
    if ((action.id === "org.freedesktop.policykit.exec" ||
         action.id === "org.tunaos.Installer.install") &&
            subject.user === "liveuser" && subject.local) {
        return polkit.Result.YES;
    }
});
RULESEOF

# ── VFS containers-storage ────────────────────────────────────────────────────
cat > /etc/containers/storage.conf << 'STOREOF'
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
STOREOF

# ── /etc/hostname ─────────────────────────────────────────────────────────────
mkdir -p /usr/lib/tmpfiles.d
echo 'f /etc/hostname 0644 - - - aurora-live' > /usr/lib/tmpfiles.d/live-hostname.conf
