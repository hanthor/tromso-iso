output_dir := "output"
workdir := output_dir
debug := "0"
installer_channel := "stable"
compression := "fast"
luks-passphrase := "testpassphrase"

# Create an XFS loopback mount at /mnt for faster VFS import.
# Idempotent: skips if /mnt is already an XFS mount.
# Must be run as root: sudo just mount-xfs
mount-xfs:
    #!/usr/bin/bash
    set -euo pipefail
    if findmnt -n -o FSTYPE /mnt 2>/dev/null | grep -q '^xfs$'; then
        echo "/mnt is already XFS — skipping"
        exit 0
    fi
    echo "Creating 45G XFS loopback at /mnt..."
    IMG="/var/tmp/tromso-xfs-loopback.img"
    truncate -s 0 "${IMG}"
    chattr +C "${IMG}" 2>/dev/null || true
    fallocate -l 45G "${IMG}"
    mkfs.xfs -f "${IMG}"
    mount -o loop "${IMG}" /mnt
    echo "XFS mounted at /mnt (45G)"
    echo ""
    echo "Now run your build with workdir on /mnt:"
    echo "  sudo just workdir=/mnt iso-sd-boot tromso"
    echo "To run rootless (replace \`user\` with your username):"
    echo "  sudo chown user:user /mnt && just workdir=/mnt iso-sd-boot tromso"
    df -h /mnt

# Build the ISO in the background, detached from the terminal session.
build-bg target:
    #!/usr/bin/bash
    set -euo pipefail
    mkdir -p {{output_dir}}
    LOG=$(realpath {{output_dir}})/build.log
    echo "Starting background build → ${LOG}"
    setsid sudo just \
        debug={{debug}} \
        installer_channel={{installer_channel}} \
        output_dir={{output_dir}} \
        compression={{compression}} \
        iso-sd-boot {{target}} \
        > "${LOG}" 2>&1 &
    disown $!
    echo "Build PID $! — tailing log (Ctrl-C is safe, build continues)"
    tail -f "${LOG}"

_payload_ref_flag target:
    @if [ -f "{{target}}/payload_ref" ]; then echo "--bootc-installer-payload-ref $(cat '{{target}}/payload_ref' | tr -d '[:space:]')"; fi

container target:
    #!/usr/bin/bash
    set -euo pipefail
    test -f "{{target}}/payload_ref" || { echo "ERROR: {{target}}/payload_ref not found"; exit 1; }
    BASE_IMAGE=$(cat {{target}}/payload_ref | tr -d '[:space:]')
    podman build --cap-add sys_admin --security-opt label=disable \
        --layers \
        --build-arg DEBUG={{debug}} \
        --build-arg INSTALLER_CHANNEL={{installer_channel}} \
        --build-arg BASE_IMAGE="${BASE_IMAGE}" \
        -t {{target}}-installer -f ./{{target}}/Containerfile ./{{target}}

iso-builder target:
    podman build --security-opt label=disable -t {{target}}-iso-builder \
        -f ./{{target}}/Containerfile.builder ./{{target}}

# Build a systemd-boot UEFI live ISO for the given target.
# Output: output/<target>-live.iso
iso-sd-boot target:
    #!/usr/bin/bash
    set -euo pipefail
    PAYLOAD_IMAGE=$(cat "{{target}}/payload_ref" | tr -d '[:space:]')

    mkdir -p {{output_dir}}
    OUTPUT_DIR=$(realpath "{{output_dir}}")
    WORKDIR=$(realpath "{{workdir}}")

    echo "=== Disk space before container build ==="
    df -h "${OUTPUT_DIR}"

    AVAILABLE_KB=$(df --output=avail -B1024 "${OUTPUT_DIR}" | tail -1 | tr -d ' ')
    REQUIRED_KB=$((20 * 1024 * 1024))
    if [ "$AVAILABLE_KB" -lt "$REQUIRED_KB" ]; then
        echo "WARNING: Only $(( AVAILABLE_KB / 1024 / 1024 ))GB free — ISO build needs ~20GB" >&2
    fi

    just debug={{debug}} installer_channel={{installer_channel}} container {{target}}

    echo "=== Disk space after container build ==="
    df -h "${OUTPUT_DIR}"

    podman rmi debian:sid 2>/dev/null || true
    podman image prune -f 2>/dev/null || true

    if [[ $(id -u) -eq 0 ]]; then
        _ns()    { bash -c "$1"; }
        _ns_rm() { rm -rf "$@"; }
    else
        _ns()    { podman unshare bash -c "$1"; }
        _ns_rm() { podman unshare rm -rf "$@"; }
    fi

    SQUASHFS="${OUTPUT_DIR}/{{target}}-rootfs.sfs"
    BOOT_TAR="${OUTPUT_DIR}/{{target}}-boot-files.tar"
    CS_STAGING="${WORKDIR}/{{target}}-cs-staging"
    SQUASHFS_ROOT="${WORKDIR}/{{target}}-sfs-root"
    trap "rm -f '${SQUASHFS}' '${BOOT_TAR}' '${OUTPUT_DIR}/{{target}}-payload.oci.tar'; _ns_rm '${CS_STAGING}' '${SQUASHFS_ROOT}' 2>/dev/null || true" EXIT

    _ns "
        set -euo pipefail
        MOUNT=\$(podman image mount localhost/{{target}}-installer)
        PATH=/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:\$PATH

        # Populate containers-storage in a staging dir on WORKDIR (large scratch space).
        # Two-step skopeo copy decouples source and destination storage configs.
        PAYLOAD_OCI='${OUTPUT_DIR}/{{target}}-payload.oci.tar'
        CS_STAGING='${CS_STAGING}'
        SQUASHFS_ROOT='${SQUASHFS_ROOT}'
        SQUASHFS_STORAGE=\"\${CS_STAGING}/var/lib/containers/storage\"
        # Storage conf for skopeo running inside the installer container.
        # Paths are container-relative: /vfs-storage is the bind-mounted SQUASHFS_STORAGE.
        STORAGE_CONF=\"\$(mktemp '${OUTPUT_DIR}'/live-storage-XXXXXX.conf)\"
        mkdir -p \"\${SQUASHFS_STORAGE}\"
        printf '[storage]\ndriver = \"vfs\"\nrunroot = \"/tmp/cs-runroot\"\ngraphroot = \"/vfs-storage\"\n' \
            > \"\${STORAGE_CONF}\"

        echo 'Exporting Tromso OCI image to archive...'
        # The tromso image is already gzip-compressed (gzip: gzip in .bst).
        # No --dest-compress-format needed; matching dakota-iso plain copy.
        skopeo copy \
            containers-storage:'${PAYLOAD_IMAGE}' \
            oci-archive:\${PAYLOAD_OCI}:'${PAYLOAD_IMAGE}'

        echo 'Importing Tromso OCI image into squashfs containers-storage...'
        # Run skopeo from inside the installer image so the VFS tar-split metadata is
        # written in a format the live ISO can read.  The build host links a newer
        # containers/storage that emits a binary tar-split format; the installer image
        # carries the same containers/storage version as the live ISO and writes the
        # JSON-based format it expects.
        podman run --rm \
            --privileged \
            -v \"\${PAYLOAD_OCI}:/payload.oci.tar:ro\" \
            -v \"\${SQUASHFS_STORAGE}:/vfs-storage\" \
            -v \"\${STORAGE_CONF}:/tmp/st.conf:ro\" \
            localhost/{{target}}-installer \
            sh -c 'mkdir -p /tmp/cs-runroot /var/tmp && CONTAINERS_STORAGE_CONF=/tmp/st.conf skopeo copy oci-archive:/payload.oci.tar:'${PAYLOAD_IMAGE}' containers-storage:'${PAYLOAD_IMAGE}''

        rm -f \"\${PAYLOAD_OCI}\" \"\${STORAGE_CONF}\"

        # mksquashfs adds each source directory as a named subdirectory — it does
        # NOT union-merge multiple sources into root. To get the VFS storage at
        # /var/lib/containers/storage/ in the squashfs (not at /tromso-cs-staging/...),
        # we build a single unified source tree using XFS reflinks (instant, ~zero space).
        echo 'Building unified squashfs source tree...'
        mkdir -p \"\${SQUASHFS_ROOT}\"
        # Use podman export | tar instead of cp -a from the overlay MOUNT.
        # fuse-overlayfs on CI runners with CONFIG_OVERLAY_FS_REDIRECT_DIR can
        # return ENOENT on files that appear in readdir() (overlay redirect artifacts).
        # podman export reads layers sequentially and produces a clean flat tar.
        EXPORT_CONT=\$(podman create localhost/{{target}}-installer /bin/true)
        podman export \"\${EXPORT_CONT}\" | tar -C \"\${SQUASHFS_ROOT}\" -xp
        podman rm \"\${EXPORT_CONT}\"
        # Merge VFS storage into the correct path within the unified source tree.
        mkdir -p \"\${SQUASHFS_ROOT}/var/lib/containers/storage\"
        cp -a \"\${CS_STAGING}/var/lib/containers/storage/.\" \
            \"\${SQUASHFS_ROOT}/var/lib/containers/storage/\"
        rm -rf \"\${CS_STAGING}\"

        # Build squashfs from the unified source tree.
        # dedup removes blocks shared between live rootfs and OCI layers (same base image).
        # -processors 4: caps parallelism to avoid OOM (32 workers exhausts RAM).
        # Compression preset: fast=zstd/3/128K (quick), release=zstd/15/1M (~20% smaller)
        SFS_LEVEL=3; SFS_BLOCK=131072
        [[ '{{compression}}' == 'release' ]] && { SFS_LEVEL=15; SFS_BLOCK=1048576; }
        mksquashfs \"\${SQUASHFS_ROOT}\" '${SQUASHFS}' \
            -noappend -comp zstd -Xcompression-level \${SFS_LEVEL} -b \${SFS_BLOCK} \
            -processors 4 \
            -e proc -e sys -e dev -e run -e tmp

        # Clean up staging dirs inside unshare — vfs files are owned by sub-uids
        # and cannot be removed by the real user outside the user namespace.
        rm -rf \"\${SQUASHFS_ROOT}\"

        tar -C \"\$MOUNT\" \
            -cf '${BOOT_TAR}' \
            ./usr/lib/modules \
            ./usr/lib/systemd/boot/efi
        podman image unmount localhost/{{target}}-installer
    "

    echo "=== Disk space after squashfs, before ISO assembly ==="
    df -h "${OUTPUT_DIR}"

    TMPDIR="${OUTPUT_DIR}" \
    PATH="/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:${PATH}" \
        bash "{{target}}/src/build-iso.sh" "${BOOT_TAR}" "${SQUASHFS}" "${OUTPUT_DIR}/{{target}}-live.iso"

    echo "ISO ready: ${OUTPUT_DIR}/{{target}}-live.iso"

# Boot a built ISO in QEMU via UEFI with serial console output on stdout.
# Exit: Ctrl-A then X
boot-iso-serial target:
    #!/usr/bin/bash
    set -euo pipefail
    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm not found" >&2; exit 1; }
    ISO=$(ls {{output_dir}}/{{target}}-live.iso 2>/dev/null | head -1 || true)
    [[ -z "$ISO" ]] && { echo "No ISO — run: just iso-sd-boot {{target}}" >&2; exit 1; }
    OVMF_CODE=""; for f in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }; done
    OVMF_VARS=$(mktemp /tmp/OVMF_VARS.XXXXXX.fd)
    for f in /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do [[ -f "$f" ]] && { cp "$f" "${OVMF_VARS}"; break; }; done
    [[ -z "$OVMF_CODE" ]] && { echo "OVMF not found" >&2; exit 1; }
    trap "rm -f ${OVMF_VARS}" EXIT
    echo "Booting ${ISO} — serial console (Ctrl-A X to quit)"
    sudo "$QEMU" -machine q35 -m 4096 -accel kvm -cpu host -smp 4 \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -drive if=none,id=live-disk,file="${ISO}",media=cdrom,format=raw,readonly=on \
        -device virtio-scsi-pci,id=scsi -device scsi-cd,drive=live-disk \
        -net nic,model=virtio -net user,hostfwd=tcp::2222-:22 \
        -serial mon:stdio -display none -no-reboot

# Boot ISO with VNC display (vncviewer 127.0.0.1:5910) and serial on telnet 4445.
boot-iso-vnc target:
    #!/usr/bin/bash
    set -euo pipefail
    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm not found" >&2; exit 1; }
    ISO=$(ls {{output_dir}}/{{target}}-live.iso 2>/dev/null | head -1 || true)
    [[ -z "$ISO" ]] && { echo "No ISO — run: just iso-sd-boot {{target}}" >&2; exit 1; }
    OVMF_CODE=""; for f in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }; done
    OVMF_VARS=$(mktemp /tmp/OVMF_VARS.XXXXXX.fd)
    for f in /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do [[ -f "$f" ]] && { cp "$f" "${OVMF_VARS}"; break; }; done
    [[ -z "$OVMF_CODE" ]] && { echo "OVMF not found" >&2; exit 1; }
    trap "rm -f ${OVMF_VARS}" EXIT
    echo "Booting ${ISO}  VNC: vncviewer 127.0.0.1:5910  Serial: telnet 127.0.0.1 4445"
    sudo "$QEMU" -machine q35 -cpu host -m 4096 -smp 4 -accel kvm \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -drive if=none,id=live-disk,file="${ISO}",media=cdrom,format=raw,readonly=on \
        -device virtio-scsi-pci,id=scsi -device scsi-cd,drive=live-disk \
        -device virtio-vga -display vnc=127.0.0.1:10 \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
        -serial telnet:127.0.0.1:4445,server,nowait -no-reboot

# Boot ISO with a writable install disk at /dev/vda for fisherman testing.
# Creates output/<target>-install.qcow2 if it doesn't exist.
boot-iso-install target:
    #!/usr/bin/bash
    set -euo pipefail
    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm not found" >&2; exit 1; }
    ISO=$(ls {{output_dir}}/{{target}}-live.iso 2>/dev/null | head -1 || true)
    [[ -z "$ISO" ]] && { echo "No ISO — run: just debug=1 iso-sd-boot {{target}}" >&2; exit 1; }
    DISK="{{output_dir}}/{{target}}-install.qcow2"
    [[ ! -f "$DISK" ]] && { echo "Creating install disk: ${DISK}"; qemu-img create -f qcow2 "${DISK}" 30G; }
    OVMF_CODE=""; for f in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }; done
    OVMF_VARS=$(mktemp /tmp/OVMF_VARS.XXXXXX.fd)
    for f in /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do [[ -f "$f" ]] && { cp "$f" "${OVMF_VARS}"; break; }; done
    [[ -z "$OVMF_CODE" ]] && { echo "OVMF not found" >&2; exit 1; }
    trap "rm -f ${OVMF_VARS}" EXIT
    echo "Booting ${ISO} with install disk ${DISK}"
    echo "  VNC:  vncviewer 127.0.0.1:5910  Serial: telnet 127.0.0.1 4445"
    echo "  SSH:  ssh -p 2222 liveuser@127.0.0.1  (password: live, debug=1 only)"
    sudo "$QEMU" -machine q35 -cpu host -m 8192 -smp 4 -accel kvm \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -drive if=none,id=live-disk,file="${ISO}",media=cdrom,format=raw,readonly=on \
        -device virtio-scsi-pci,id=scsi -device scsi-cd,drive=live-disk \
        -drive if=none,id=install-disk,file="${DISK}",format=qcow2 \
        -device virtio-blk-pci,drive=install-disk \
        -device virtio-vga -display vnc=127.0.0.1:10 \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
        -serial telnet:127.0.0.1:4445,server,nowait -no-reboot

# Boot an already-installed disk image directly (no ISO) with serial on stdin/stdout.
# Useful for debugging the installed system after manual or fisherman install.
# Usage: just boot-installed tromso
boot-installed target:
    #!/usr/bin/bash
    set -euo pipefail
    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm not found" >&2; exit 1; }
    DISK="{{output_dir}}/{{target}}-install.qcow2"
    [[ ! -f "$DISK" ]] && { echo "No install disk: ${DISK}" >&2; exit 1; }
    OVMF_CODE=""; for f in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }; done
    OVMF_VARS=$(mktemp /tmp/OVMF_VARS.XXXXXX.fd)
    for f in /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do [[ -f "$f" ]] && { cp "$f" "${OVMF_VARS}"; break; }; done
    [[ -z "$OVMF_CODE" ]] && { echo "OVMF not found" >&2; exit 1; }
    trap "rm -f ${OVMF_VARS}" EXIT
    echo "Booting installed disk: ${DISK}"
    echo "  Serial console (Ctrl-A X to quit QEMU)"
    echo "  SSH: ssh -p 2222 root@127.0.0.1  (password: root)"
    sudo "$QEMU" -machine q35 -cpu host -m 8192 -smp 4 -accel kvm \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -drive if=none,id=disk0,file="${DISK}",format=qcow2 \
        -device virtio-blk-pci,drive=disk0 \
        -net nic,model=virtio -net user,hostfwd=tcp::2222-:22 \
        -serial mon:stdio -display none -no-reboot

# SSH into a running boot-iso-install VM and run fisherman to install to /dev/vda.
# Requires: just debug=1 boot-iso-install <target>  running in another terminal.
# Uses composeFsBackend=true so no bootupd needed and no scratch disk required.
install target:
    #!/usr/bin/bash
    set -euo pipefail
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o IdentitiesOnly=yes -o PreferredAuthentications=password"
    SSH_LIVE="sshpass -p live ssh $SSH_OPTS -p 2222 liveuser@127.0.0.1"
    SSH_ROOT="sshpass -p root ssh $SSH_OPTS -p 2222 root@127.0.0.1"
    SCP_LIVE="sshpass -p live scp $SSH_OPTS -P 2222"
    PAYLOAD_REF="$(cat '{{target}}/payload_ref' 2>/dev/null | tr -d '[:space:]' || echo "localhost/{{target}}:latest")"
    echo "Waiting for SSH..."
    for i in $(seq 1 40); do $SSH_LIVE true 2>/dev/null && break; sleep 5; echo "  attempt ${i}/40..."; done
    $SSH_LIVE true || { echo "ERROR: SSH timed out"; exit 1; }
    echo "SSH ready."
    RECIPE=$(mktemp /tmp/install-XXXXXX.json)
    trap "rm -f '${RECIPE}'" EXIT
    printf '{"disk":"/dev/vda","filesystem":"xfs","image":"containers-storage:%s","composeFsBackend":true,"bootloader":"systemd","hostname":"aurora","flatpaks":[]}\n' "${PAYLOAD_REF}" > "${RECIPE}"
    $SCP_LIVE "${RECIPE}" liveuser@127.0.0.1:/tmp/install-recipe.json
    echo "Uploaded recipe. Running fisherman..."
    $SSH_ROOT '
        FISHERMAN=$(ls /var/lib/flatpak/app/org.bootcinstaller.Installer/x86_64/master/active/files/bin/fisherman \
                       /var/lib/flatpak/app/org.bootcinstaller.Installer.Devel/x86_64/master/active/files/bin/fisherman \
                    2>/dev/null | head -1)
        [[ -z "$FISHERMAN" ]] && { echo "fisherman not found"; exit 1; }
        "$FISHERMAN" /tmp/install-recipe.json
    '
    echo "Install finished."

# Like 'install' but with LUKS encryption.
luks-install target:
    #!/usr/bin/bash
    set -euo pipefail
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o IdentitiesOnly=yes -o PreferredAuthentications=password"
    SSH_LIVE="sshpass -p live ssh $SSH_OPTS -p 2222 liveuser@127.0.0.1"
    SSH_ROOT="sshpass -p root ssh $SSH_OPTS -p 2222 root@127.0.0.1"
    SCP_LIVE="sshpass -p live scp $SSH_OPTS -P 2222"
    PAYLOAD_REF="$(cat '{{target}}/payload_ref' 2>/dev/null | tr -d '[:space:]' || echo "localhost/{{target}}:latest")"
    PASSPHRASE="{{luks-passphrase}}"
    echo "Waiting for SSH..."
    for i in $(seq 1 40); do $SSH_LIVE true 2>/dev/null && break; sleep 5; echo "  attempt ${i}/40..."; done
    $SSH_LIVE true || { echo "ERROR: SSH timed out"; exit 1; }
    RECIPE=$(mktemp /tmp/luks-XXXXXX.json)
    trap "rm -f '${RECIPE}'" EXIT
    printf '{"disk":"/dev/vda","filesystem":"xfs","image":"containers-storage:%s","composeFsBackend":true,"bootloader":"systemd","hostname":"aurora","encryption":{"type":"luks-passphrase","passphrase":"%s"},"flatpaks":[]}\n' "${PAYLOAD_REF}" "${PASSPHRASE}" > "${RECIPE}"
    $SCP_LIVE "${RECIPE}" liveuser@127.0.0.1:/tmp/luks-recipe.json
    echo "Running fisherman with LUKS..."
    $SSH_ROOT '
        FISHERMAN=$(ls /var/lib/flatpak/app/org.bootcinstaller.Installer/x86_64/master/active/files/bin/fisherman \
                       /var/lib/flatpak/app/org.bootcinstaller.Installer.Devel/x86_64/master/active/files/bin/fisherman \
                    2>/dev/null | head -1)
        [[ -z "$FISHERMAN" ]] && { echo "fisherman not found"; exit 1; }
        "$FISHERMAN" /tmp/luks-recipe.json
    '
    echo "LUKS install finished. Passphrase: ${PASSPHRASE}"
