image-builder := "image-builder"
image-builder-dev := "image-builder-dev"

# Output directory for built ISOs and intermediate artifacts.
# Override with: just output_dir=/your/path iso-sd-boot tromso
output_dir := "output"

# Set to 1 to enable SSH in the live session for debugging.
# Example: just debug=1 output_dir=/tmp/out iso-sd-boot tromso
# Never use debug=1 for production/release ISOs.
debug := "0"

# Set to "dev" to pull the tuna-installer dev build (continuous-dev release).
# Example: just installer_channel=dev iso-sd-boot tromso
installer_channel := "stable"

# LUKS passphrase used by luks-install for testing.
luks-passphrase := "testpassphrase"

# Squashfs compression preset:
#   fast    (default) — zstd level 3,  128K blocks — quick local builds/CI
#   release           — zstd level 15, 1M blocks   — ~20% smaller, ~5× slower
# Example: just compression=release iso-sd-boot tromso
compression := "fast"

# Build the ISO in the background, detached from the terminal session.
# Logs are written to {{output_dir}}/build.log and tailed live.
# Usage: just build-bg tromso
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

# Helper: returns "--bootc-installer-payload-ref <ref>" or "" if no payload_ref file
_payload_ref_flag target:
    @if [ -f "{{target}}/payload_ref" ]; then echo "--bootc-installer-payload-ref $(cat '{{target}}/payload_ref' | tr -d '[:space:]')"; fi

container target:
    sudo podman build --cap-add sys_admin --security-opt label=disable \
        --layers \
        --build-arg DEBUG={{debug}} \
        --build-arg INSTALLER_CHANNEL={{installer_channel}} \
        -t {{target}}-installer ./{{target}}

# Build the Debian-based ISO assembly container for the given target.
iso-builder target:
    podman build --security-opt label=disable -t {{target}}-iso-builder \
        -f ./{{target}}/Containerfile.builder ./{{target}}

# Build a systemd-boot UEFI live ISO for the given target.
#
# Uses a two-container approach:
#   1. localhost/<target>-installer — the live environment (3-stage Containerfile)
#   2. localhost/<target>-iso-builder — Debian ISO assembly tools (Containerfile.builder)
#
# Output: output/<target>-live.iso
iso-sd-boot target:
    #!/usr/bin/bash
    set -euo pipefail

    # Read payload ref from file (defaults to localhost/<target>:latest if missing)
    PAYLOAD_REF="$(cat '{{target}}/payload_ref' 2>/dev/null | tr -d '[:space:]' || echo "localhost/{{target}}:latest")"

    just debug={{debug}} installer_channel={{installer_channel}} container {{target}}
    mkdir -p {{output_dir}}
    OUTPUT_DIR=$(realpath "{{output_dir}}")

    if [[ $(id -u) -eq 0 ]]; then
        _ns()    { bash -c "$1"; }
        _ns_rm() { rm -rf "$@"; }
    else
        _ns()    { podman unshare bash -c "$1"; }
        _ns_rm() { podman unshare rm -rf "$@"; }
    fi

    SQUASHFS="${OUTPUT_DIR}/{{target}}-rootfs.sfs"
    BOOT_TAR="${OUTPUT_DIR}/{{target}}-boot-files.tar"
    CS_STAGING="${OUTPUT_DIR}/{{target}}-cs-staging"
    SQUASHFS_ROOT="${OUTPUT_DIR}/{{target}}-sfs-root"
    trap "rm -f '${SQUASHFS}' '${BOOT_TAR}' '${OUTPUT_DIR}/{{target}}-payload.oci.tar'; _ns_rm '${CS_STAGING}' '${SQUASHFS_ROOT}' 2>/dev/null || true" EXIT
    echo "Building squashfs and boot tar from localhost/{{target}}-installer..."
    _ns "
        set -euo pipefail
        MOUNT=\$(podman image mount localhost/{{target}}-installer)
        PATH=/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:\$PATH

        PAYLOAD_OCI='${OUTPUT_DIR}/{{target}}-payload.oci.tar'
        CS_STAGING='${CS_STAGING}'
        SQUASHFS_ROOT='${SQUASHFS_ROOT}'
        SQUASHFS_STORAGE=\"\${CS_STAGING}/var/lib/containers/storage\"
        STORAGE_CONF=\"\$(mktemp '${OUTPUT_DIR}'/live-storage-XXXXXX.conf)\"
        mkdir -p \"\${SQUASHFS_STORAGE}\"
        printf '[storage]\ndriver = \"vfs\"\nrunroot = \"/tmp/cs-runroot\"\ngraphroot = \"/vfs-storage\"\n' \
            > \"\${STORAGE_CONF}\"

        echo 'Exporting Aurora Tromso OCI image to archive...'
        skopeo copy \
            containers-storage:${PAYLOAD_REF} \
            oci-archive:\${PAYLOAD_OCI}:${PAYLOAD_REF}

        echo 'Importing Aurora Tromso OCI image into squashfs containers-storage...'
        podman run --rm \
            --privileged \
            -v \"\${PAYLOAD_OCI}:/payload.oci.tar:ro\" \
            -v \"\${SQUASHFS_STORAGE}:/vfs-storage\" \
            -v \"\${STORAGE_CONF}:/tmp/st.conf:ro\" \
            localhost/{{target}}-installer \
            sh -c 'mkdir -p /tmp/cs-runroot /var/tmp && CONTAINERS_STORAGE_CONF=/tmp/st.conf skopeo copy oci-archive:/payload.oci.tar:${PAYLOAD_REF} containers-storage:${PAYLOAD_REF}'

        rm -f \"\${PAYLOAD_OCI}\" \"\${STORAGE_CONF}\"

        echo 'Building unified squashfs source tree...'
        mkdir -p \"\${SQUASHFS_ROOT}\"
        cp -a --reflink=auto \"\${MOUNT}/.\" \"\${SQUASHFS_ROOT}/\" 2>/dev/null || \
            cp -a \"\${MOUNT}/.\" \"\${SQUASHFS_ROOT}/\" 2>/dev/null || true
        mkdir -p \"\${SQUASHFS_ROOT}/var/lib/containers/storage\"
        cp -a \"\${CS_STAGING}/var/lib/containers/storage/.\" \
            \"\${SQUASHFS_ROOT}/var/lib/containers/storage/\"
        rm -rf \"\${CS_STAGING}\"

        SFS_LEVEL=3; SFS_BLOCK=131072
        [[ '{{compression}}' == 'release' ]] && { SFS_LEVEL=15; SFS_BLOCK=1048576; }
        mksquashfs \"\${SQUASHFS_ROOT}\" '${SQUASHFS}' \
            -noappend -comp zstd -Xcompression-level \${SFS_LEVEL} -b \${SFS_BLOCK} \
            -processors 4 \
            -e proc -e sys -e dev -e run -e tmp

        rm -rf \"\${SQUASHFS_ROOT}\"

        tar -C \"\$MOUNT\" \
            -cf '${BOOT_TAR}' \
            ./usr/lib/modules \
            ./usr/lib/systemd/boot/efi
        podman image umount localhost/{{target}}-installer
    "

    TMPDIR="${OUTPUT_DIR}" \
    PATH="/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:${PATH}" \
        bash "{{target}}/src/build-iso.sh" "${BOOT_TAR}" "${SQUASHFS}" "${OUTPUT_DIR}/{{target}}-live.iso"

    echo "ISO ready: ${OUTPUT_DIR}/{{target}}-live.iso"

# Boot a built ISO in QEMU via UEFI (OVMF) with serial console output on stdout.
# Exit: Ctrl-A then X
boot-iso-serial target:
    #!/usr/bin/bash
    set -euo pipefail
    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm \
               /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm / qemu-system-x86_64 not found" >&2; exit 1; }
    ISO=$(ls \
        {{output_dir}}/{{target}}-live.iso \
        2>/dev/null | head -1 || true)
    if [[ -z "$ISO" ]]; then
        echo "No ISO found for '{{target}}' — run: just iso-sd-boot {{target}}" >&2
        exit 1
    fi

    OVMF_CODE=""
    for f in \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
        /usr/share/ovmf/OVMF.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    OVMF_VARS_SRC=""
    for f in \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do
        [[ -f "$f" ]] && { OVMF_VARS_SRC="$f"; break; }
    done
    if [[ -z "$OVMF_CODE" ]]; then
        echo "OVMF firmware not found — install edk2-ovmf or ovmf" >&2
        exit 1
    fi

    OVMF_VARS=$(mktemp /tmp/OVMF_VARS.XXXXXX.fd)
    [[ -n "$OVMF_VARS_SRC" ]] && cp "${OVMF_VARS_SRC}" "${OVMF_VARS}"
    trap "rm -f ${OVMF_VARS}" EXIT

    echo "Booting ${ISO} via UEFI — serial console below (Ctrl-A X to quit)"
    echo "SSH available on localhost:2222 (user: liveuser, password: live) if built with debug=1"
    sudo "$QEMU" \
        -machine q35 \
        -m 4096 \
        -accel kvm \
        -cpu host \
        -smp 4 \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -drive if=none,id=live-disk,file="${ISO}",media=cdrom,format=raw,readonly=on \
        -device virtio-scsi-pci,id=scsi \
        -device scsi-cd,drive=live-disk \
        -net nic,model=virtio -net user,hostfwd=tcp::2222-:22 \
        -serial mon:stdio \
        -display none \
        -no-reboot

# Boot ISO with a writable install disk attached (for testing fisherman installs).
# Creates a fresh 30 GB qcow2 at output/<target>-install.qcow2.
# VNC on :10 (port 5910), serial telnet 4445, SSH port 2222 (debug=1 only).
# Exit: send SIGTERM or use virsh / kill.
boot-iso-install target:
    #!/usr/bin/bash
    set -euo pipefail
    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm \
               /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm / qemu-system-x86_64 not found" >&2; exit 1; }
    ISO=$(ls {{output_dir}}/{{target}}-live.iso 2>/dev/null | head -1 || true)
    [[ -z "$ISO" ]] && { echo "No ISO found — run: just debug=1 iso-sd-boot {{target}}" >&2; exit 1; }

    DISK="{{output_dir}}/{{target}}-install.qcow2"
    if [[ ! -f "$DISK" ]]; then
        echo "Creating fresh install disk: ${DISK}"
        qemu-img create -f qcow2 "${DISK}" 30G
    fi


    OVMF_CODE=""
    for f in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd \
              /usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    OVMF_VARS=$(mktemp /tmp/OVMF_VARS.XXXXXX.fd)
    for f in /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd \
              /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do
        [[ -f "$f" ]] && { cp "$f" "${OVMF_VARS}"; break; }
    done
    [[ -z "$OVMF_CODE" ]] && { echo "OVMF firmware not found" >&2; exit 1; }
    trap "rm -f ${OVMF_VARS}" EXIT

    echo "Booting ${ISO} with install disk ${DISK}"
    echo "  VNC:    vncviewer 127.0.0.1:5910  (display :10)"
    echo "  Serial: telnet 127.0.0.1 4445"
    echo "  SSH:    ssh -p 2222 liveuser@127.0.0.1  (password: live, debug=1 only)"
    echo "  Disk:   /dev/vda inside the VM"
    sudo "$QEMU" \
        -machine q35 -cpu host -m 12288 -smp 4 -accel kvm \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -drive if=none,id=live-disk,file="${ISO}",media=cdrom,format=raw,readonly=on \
        -device virtio-scsi-pci,id=scsi \
        -device scsi-cd,drive=live-disk \
        -drive if=none,id=install-disk,file="${DISK}",format=qcow2 \
        -device virtio-blk-pci,drive=install-disk \
        -device virtio-vga \
        -display vnc=127.0.0.1:10 \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
        -serial telnet:127.0.0.1:4445,server,nowait \
        -no-reboot

# SSH into the live session and run fisherman to install Aurora onto /dev/vda.
# Requires: just debug=1 boot-iso-install <target>  (running in another terminal)
# Uses containers-storage ref so no network pull is needed (image is in squashfs).
install target:
    #!/usr/bin/bash
    set -euo pipefail
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o LogLevel=ERROR -o ConnectTimeout=5 \
              -o IdentitiesOnly=yes -o PreferredAuthentications=password"
    SSH="sshpass -p live ssh $SSH_OPTS -p 2222"
    SCP="sshpass -p live scp $SSH_OPTS -P 2222"
    HOST="liveuser@127.0.0.1"

    PAYLOAD_REF="$(cat '{{target}}/payload_ref' 2>/dev/null | tr -d '[:space:]' || echo "localhost/{{target}}:latest")"

    echo "Waiting for SSH on port 2222..."
    for i in $(seq 1 40); do
        $SSH $HOST true 2>/dev/null && break
        sleep 5
        echo "  attempt ${i}/40..."
    done
    $SSH $HOST true || { echo "ERROR: SSH timed out after 200 s"; exit 1; }
    echo "SSH ready."

    RECIPE=$(mktemp /tmp/install-recipe-XXXXXX.json)
    trap "rm -f '${RECIPE}'" EXIT
    # composeFsBackend=true: fisherman exports the OCI image to an 8G tmpfs on
    # the target disk, bypassing the bootupd check and /var/lib/containers space
    # constraints. This is the same approach dakota-iso uses.
    printf '{"disk":"/dev/vda","filesystem":"xfs","image":"containers-storage:%s","composeFsBackend":true,"bootloader":"systemd","hostname":"aurora","flatpaks":[]}\n' \
        "${PAYLOAD_REF}" > "${RECIPE}"
    $SCP "${RECIPE}" "$HOST":/tmp/install-recipe.json
    echo "Uploaded recipe → /tmp/install-recipe.json"
    echo "Running fisherman (composeFsBackend=true — no scratch disk needed)..."
    sshpass -p root ssh $SSH_OPTS -p 2222 root@127.0.0.1 '
        FISHERMAN=$(ls /var/lib/flatpak/app/org.bootcinstaller.Installer/x86_64/master/active/files/bin/fisherman \
                       /var/lib/flatpak/app/org.bootcinstaller.Installer.Devel/x86_64/master/active/files/bin/fisherman \
                    2>/dev/null | head -1)
        [[ -z "$FISHERMAN" ]] && { echo "fisherman not found"; exit 1; }
        echo "Using fisherman: $FISHERMAN"
        "$FISHERMAN" /tmp/install-recipe.json
    '
    echo ""
    echo "Install finished. Reboot the VM and boot from the install disk."

# Like 'install' but adds LUKS encryption with the configured passphrase.
luks-install target:
    #!/usr/bin/bash
    set -euo pipefail
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o LogLevel=ERROR -o ConnectTimeout=5 \
              -o IdentitiesOnly=yes -o PreferredAuthentications=password"
    SSH="sshpass -p live ssh $SSH_OPTS -p 2222"
    SCP="sshpass -p live scp $SSH_OPTS -P 2222"
    HOST="liveuser@127.0.0.1"

    PAYLOAD_REF="$(cat '{{target}}/payload_ref' 2>/dev/null | tr -d '[:space:]' || echo "localhost/{{target}}:latest")"
    PASSPHRASE="{{luks-passphrase}}"

    echo "Waiting for SSH on port 2222..."
    for i in $(seq 1 40); do
        $SSH $HOST true 2>/dev/null && break
        sleep 5
        echo "  attempt ${i}/40..."
    done
    $SSH $HOST true || { echo "ERROR: SSH timed out after 200 s"; exit 1; }
    echo "SSH ready."

    RECIPE=$(mktemp /tmp/luks-recipe-XXXXXX.json)
    trap "rm -f '${RECIPE}'" EXIT
    printf '{"disk":"/dev/vda","filesystem":"xfs","image":"containers-storage:%s","composeFsBackend":true,"bootloader":"systemd","hostname":"aurora","encryption":{"type":"luks-passphrase","passphrase":"%s"},"flatpaks":[]}\n' \
        "${PAYLOAD_REF}" "${PASSPHRASE}" > "${RECIPE}"
    $SCP "${RECIPE}" "$HOST":/tmp/luks-recipe.json
    echo "Uploaded LUKS recipe → /tmp/luks-recipe.json"
    echo "Running fisherman with LUKS encryption (composeFsBackend=true)..."
    sshpass -p root ssh $SSH_OPTS -p 2222 root@127.0.0.1 '
        FISHERMAN=$(ls /var/lib/flatpak/app/org.bootcinstaller.Installer/x86_64/master/active/files/bin/fisherman \
                       /var/lib/flatpak/app/org.bootcinstaller.Installer.Devel/x86_64/master/active/files/bin/fisherman \
                    2>/dev/null | head -1)
        [[ -z "$FISHERMAN" ]] && { echo "fisherman not found"; exit 1; }
        "$FISHERMAN" /tmp/luks-recipe.json
    '
    echo ""
    echo "LUKS install finished. Reboot the VM and boot from the install disk."
    echo "You will be prompted for passphrase: ${PASSPHRASE}"

# Boot ISO with VNC display (for seeing the KDE desktop)
boot-iso-vnc target:
    #!/usr/bin/bash
    set -euo pipefail
    QEMU=$(command -v /usr/libexec/qemu-kvm /usr/bin/qemu-kvm \
               /usr/bin/qemu-system-x86_64 2>/dev/null | head -1)
    [[ -z "$QEMU" ]] && { echo "qemu-kvm / qemu-system-x86_64 not found" >&2; exit 1; }
    ISO=$(ls {{output_dir}}/{{target}}-live.iso 2>/dev/null | head -1 || true)
    if [[ -z "$ISO" ]]; then
        echo "No ISO found — run: just iso-sd-boot {{target}}" >&2; exit 1
    fi

    OVMF_CODE=""
    for f in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd \
              /usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
        [[ -f "$f" ]] && { OVMF_CODE="$f"; break; }
    done
    OVMF_VARS=$(mktemp /tmp/OVMF_VARS.XXXXXX.fd)
    for f in /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd \
              /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do
        [[ -f "$f" ]] && { cp "$f" "${OVMF_VARS}"; break; }
    done
    [[ -z "$OVMF_CODE" ]] && { echo "OVMF firmware not found" >&2; exit 1; }
    trap "rm -f ${OVMF_VARS}" EXIT

    echo "Booting ${ISO}"
    echo "  VNC:    vncviewer 127.0.0.1:5910  (display :10)"
    echo "  Serial: telnet 127.0.0.1 4445"
    echo "  SSH:    ssh -p 2222 liveuser@127.0.0.1  (debug=1 only)"
    sudo "$QEMU" \
        -machine q35 -cpu host -m 4096 -smp 4 -accel kvm \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -drive if=none,id=live-disk,file="${ISO}",media=cdrom,format=raw,readonly=on \
        -device virtio-scsi-pci,id=scsi \
        -device scsi-cd,drive=live-disk \
        -device virtio-vga \
        -display vnc=127.0.0.1:10 \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
        -serial telnet:127.0.0.1:4445,server,nowait \
        -no-reboot
