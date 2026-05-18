# tromso-iso — AI Assistant Mandates

## tromso-iso IS the KDE version of dakota-iso

`tromso-iso` is a direct KDE Plasma port of `projectbluefin/dakota-iso`.
**All ISO installer patterns, Containerfile structure, justfile recipes, and
build infrastructure MUST be copied from the reference repo at
`/var/home/james/reference-repos/dakota-iso/`.**

When in doubt, check what dakota-iso does and do the same thing — replacing only
the distro-specific parts (GDM→SDDM, GNOME config→KDE config, product name).

**Never invent workarounds.** If something doesn't work, read dakota-iso first.

---

## Architecture (mirrors dakota-iso exactly)

### Containerfile — three stages

| Stage | Purpose |
|-------|---------|
| `tromso-ref` | Pull base tromso OCI image; extract kernel/initramfs for the ISO |
| `initramfs-builder` | Debian + dracut; build the live initramfs |
| `final` | `FROM ${BASE_IMAGE}` (the tromso OCI); configure live env on top |

The squashfs embedded in the ISO contains **the base tromso OCI image** as VFS
containers-storage — not the live-env layer.  The live-env changes (SDDM
autologin, SSH, polkit, VFS storage.conf) exist only in the upper container layer
and are never installed to disk.

### iso-sd-boot recipe

1. Build the live container image with `podman build` (3-stage Containerfile).
2. Export the **base payload image** (not the live image) to an OCI-archive with
   `skopeo copy`.  Use `--dest-compress-format gzip --dest-force-compress-format`
   to ensure gzip layers (fisherman hardcodes zstd, bootc composefs requires gzip;
   pre-compressing with gzip avoids a recompression deadlock).
3. Import the OCI-archive into VFS containers-storage **inside the live container**
   (via `podman run`) so that tar-split metadata is in the format the live ISO's
   containers-storage version expects.
4. Squash the VFS storage into `tromso.squashfs` with `mksquashfs`.
5. Extract the kernel and initramfs from the `tromso-ref` stage.
6. Build the ISO with `xorriso`.

### composeFsBackend

**Always set `composeFsBackend: true` in `etc/bootc-installer/recipe.json`.**

With `composeFsBackend: true`:
- fisherman exports the OCI image to an OCI layout in `/var/tmp` on the TARGET
  disk before calling bootc.
- bootc receives `--composefs-backend --source-imgref oci:/var/tmp/oci-cache`.
- The `-v /var/lib/containers:/var/lib/containers` bind-mount is **NOT** passed
  to the container.
- bootc does **not** require `bootupd` in this path (same as dakota).

Do **not** use `composeFsBackend: false` — that path requires `bootupctl` which
is not shipped in the tromso image.

---

## KDE-specific differences from dakota-iso

These are the ONLY intentional deviations from dakota-iso.  Everything else must
match dakota.

| Component | dakota-iso | tromso-iso |
|-----------|-----------|-----------|
| Display manager | GDM autologin | SDDM autologin |
| Screen lock config | dconf | kscreenlockerrc |
| Power management | dconf | powermanagementprofilesrc |
| DRM device access | not needed | `usermod -aG video,render liveuser` |
| skopeo compress | (no flag) | `--dest-compress-format gzip --dest-force-compress-format` |
| sshd_config fixes | (none) | Remove `PerSourcePenalties`, `GSSAPIAuthentication` (not in freedesktop-sdk OpenSSH) |
| sudo setuid | (not needed) | `chmod u+s /usr/bin/sudo` (BST strips setuid bits) |

---

## Aurora Branding

Aurora branding is embedded in the base tromso OCI image by `elements/tromso/logos.bst`.
It provides:
- `tromso.png` icons in `/usr/share/icons/hicolor/{16,24,32,48,64,128,256,512}x*/apps/`
- `distributor-logo.svg` in hicolor/scalable
- SDDM theme logo, Plymouth watermark, KDE splash screen
- `os-release`: `ID=aurora`, `NAME="Aurora Tromso"`, `LOGO=start-here-kde`

`Icon=tromso` in the installer `.desktop` entries will resolve from these icons.
The welcome tour image (`tromso-welcome.png`) is installed from `src/images/` by
`configure-live.sh` (not the Containerfile).

---

## Reference

- **Authoritative reference**: `/var/home/james/reference-repos/dakota-iso/`
- **Base tromso image source**: `hanthor/tromso` (BuildStream project)
- **Custom instructions doc**: `AGENTS.md` in `hanthor/tromso`
