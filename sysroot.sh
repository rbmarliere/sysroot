#!/bin/sh

prompt_input_yN()
{
    printf "$1? [y|N] " ; shift
    while true; do
        read -k 1 yn
        case ${yn} in
            [Yy]* ) printf "\n" && return 0; break;;
            \n ) printf "\n" && return 1; break;;
            * ) return 1;;
        esac
    done
}

sysroot_chroot()
{
    if [ $# -lt 2 ]; then
        printf "usage: sysroot-chroot path\n"
        return 1
    fi
    sysroot_mount $1
    chroot $1 /bin/sh --login
}

sysroot_mount()
{
    if [ $# -lt 2 ]; then
        printf "usage: sysroot-mount path\n"
        return 1
    fi
    if [ "$(mount | grep $1)" != "" ]; then
        return 0
    fi
    if [ "$(/etc/init.d/qemu-binfmt status | grep started)" = "" ]; then
        /etc/init.d/qemu-binfmt start
    fi
    cp /etc/resolv.conf $1/etc/resolv.conf
    mkdir -p $1/proc && mount --bind /proc $1/proc
    mkdir -p $1/sys  && mount --bind /sys $1/sys
    mkdir -p $1/dev  && mount --bind /dev $1/dev
}

sysroot_install()
{
    CFLAGS="-O2 -pipe -march=armv7-a -mtune=cortex-a53 -mfpu=neon-vfpv4 -mfloat-abi=hard"
    CTARGET=armv7a-hardfloat-linux-gnueabi
    SDCARD=/dev/mmcblk0
    STAGE_BALL=${HOME}/Downloads/stage3-latest.tar.xz
    STAGE_URL="http://ftp.osuosl.org/pub/funtoo/funtoo-current/arm-32bit/raspi3/stage3-latest.tar.xz"
    SYSROOT=/home/sysroots/${CTARGET}

    if [ "$(lsmod | grep kvm_intel)" = "" ]; then
        modprobe kvm_intel
        if [ $? -ne 0 ]; then
            printf "error: can't load kvm_intel kernel module\n"
            return 1;
        fi
    fi

    if [ -d ${SYSROOT} ]; then
        if prompt_input_yN "backup previous sysroot to ${SYSROOT}.old\n"; then
            mv ${SYSROOT} ${SYSROOT}.old
            mkdir -p ${SYSROOT}
        fi
    fi

    if prompt_input_yN "download stage3-latest for ARM architecture\n"; then
        mkdir -p ${HOME}/Downloads
        [ -f ${STAGE_BALL} ] && mv ${STAGE_BALL} ${STAGE_BALL}.bak
        wget ${STAGE_URL} -O ${STAGE_BALL}
    fi

    if prompt_input_yN "extract ${STAGE_BALL} in ${SYSROOT}\n"; then
        mkdir -p ${SYSROOT}
        tar xpfv ${STAGE_BALL} -C ${SYSROOT}
    fi

    portage_dirs="/etc/portage/package.keywords /etc/portage/package.mask /etc/portage/package.use"
    printf "${portage_dirs}\n" | tr ' ' '\n' | while read dir; do
        if [ ! -d ${dir} ]; then
            mv ${dir} ${dir}"_file"
            mkdir -p ${dir}
            mv ${dir}"_file" ${dir}
        fi
    done

    if prompt_input_yN "merge app-emulation/qemu"; then
        if [ ! -d /etc/portage/package.use ]; then
            printf 'error: convert /etc/portage/package.use to a directory'
            return 1
        else
            printf 'app-emulation/qemu static-user' > /etc/portage/package.use/qemu
            printf 'dev-libs/libpcre static-libs' >> /etc/portage/package.use/qemu
            printf 'sys-apps/attr static-libs' >> /etc/portage/package.use/qemu
            printf 'dev-libs/glib static-libs' >> /etc/portage/package.use/qemu
            printf 'sys-libs/zlib static-libs' >> /etc/portage/package.use/qemu
        fi
        if [ "$(grep QEMU_SOFT_MMU_TARGETS /etc/portage/make.conf)" = "" ]; then
            printf 'QEMU_SOFTMMU_TARGETS="arm"' >> /etc/portage/make.conf
        fi
        if [ "$(grep QEMU_USER_TARGETS /etc/portage/make.conf)" = "" ]; then
            printf 'QEMU_USER_TARGETS="arm"' >> /etc/portage/make.conf
        fi
        emerge app-emulation/qemu
    fi

    if prompt_input_yN "install static qemu binary on ${SYSROOT}"; then
        quickpkg app-emulation/qemu
        ROOT=${SYSROOT}/ emerge --usepkgonly --oneshot --nodeps qemu
    fi

    sysroot_mount ${SYSROOT}

    if prompt_input_yN "prepare the sysroot"; then
        if [ ! -f ${SYSROOT}/prepare.sh ]; then
            cat > ${SYSROOT}/prepare.sh << EOF
#!/bin/sh
passwd
printf '/dev/mapper/rpi-root    /           ext4    defaults,noatime,errors=remount-ro,discard   0 1' >  /etc/fstab
printf '/dev/mapper/rpi-swap    none        swap    defaults,noatime,discard                     0 0' >> /etc/fstab
ego sync
emerge -a cryptsetup genkernel dropbear raspberrypi-firmware networkmanager wireless-tools lvm2
dispatch-conf
emerge -a cryptsetup genkernel dropbear raspberrypi-firmware networkmanager wireless-tools lvm2
rc-update add NetworkManager default
rc-update add sshd default
rc-update add swclock boot
rc-update del hwclock boot
rm -f /etc/dropbear
mkdir -p /etc/dropbear
dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key
dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key
dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key
printf '' > /etc/dropbear/authorized_keys
chmod 700 /etc/dropbear
EOF
            chmod +x ${SYSROOT}/prepare.sh
        fi
        chroot ${SYSROOT} /bin/bash -c "/bin/bash /prepare.sh"
        rm ${SYSROOT}/prepare.sh
    fi

    if prompt_input_yN "merge crossdev"; then
        if [ "$(grep crossdev-99999999 /etc/portage/package.unmask)" = "" ]; then
            printf "=sys-devel/crossdev-99999999" >> /etc/portage/package.unmask
        fi
        if [ ! -d /etc/portage/package.keywords ]; then
            printf 'error: convert /etc/portage/package.keywords to a directory'
            return 1
        else
            printf "sys-devel/crossdev **" > /etc/portage/package.keywords/crossdev
        fi
        emerge crossdev
    fi

    if prompt_input_yN "build cross-${CTARGET} toolchain"; then
        if [ ! -d /var/git/gentoo-vanilla ]; then
            git clone git://github.com/gentoo/gentoo.git /var/git/gentoo-vanilla
        fi
        git --git-dir=/var/git/gentoo-vanilla/.git --work-tree=/var/git/gentoo-vanilla pull origin \
        echo "gentoo-vanilla" > /var/git/gentoo-vanilla/profiles/repo_name
        cat > /etc/portage/repos.conf/gentoo-vanilla << EOF
[gentoo-vanilla]
location = /var/git/gentoo-vanilla
sync-type = git
sync-uri = git://github.com/gentoo/gentoo.git
auto-sync = no
EOF
        cat > /etc/portage/repos.conf/crossdev << EOF
[crossdev]
location = /var/git/crossdev
masters = gentoo-vanilla
auto-sync = no
use-manifests = true
thin-manifests = true
EOF
        mkdir -p /var/git/crossdev/profiles
        chown -R portage:portage /var/git/crossdev
        echo "crossdev" > /var/git/crossdev/profiles/repo_name
        rm -rf /var/git/crossdev/cross-${CTARGET}
        crossdev -S -oO /var/git/crossdev/ -t ${CTARGET}
        rm -f /etc/portage/repos.conf/{crossdev,gentoo-vanilla}
    fi

    if prompt_input_yN "clean and update sources from raspberrypi/linux"; then
        if [ ! -d /usr/src/linux-rpi-vanilla ]; then
            git clone https://github.com/raspberrypi/linux.git /usr/src/linux-rpi-vanilla
        fi
        git --git-dir=/usr/src/linux-rpi-vanilla/.git --work-tree=/usr/src/linux-rpi-vanilla clean -fdx
        git --git-dir=/usr/src/linux-rpi-vanilla/.git --work-tree=/usr/src/linux-rpi-vanilla checkout master
        git --git-dir=/usr/src/linux-rpi-vanilla/.git --work-tree=/usr/src/linux-rpi-vanilla fetch --all
        git --git-dir=/usr/src/linux-rpi-vanilla/.git --work-tree=/usr/src/linux-rpi-vanilla branch -D rpi-4.9.y
        git --git-dir=/usr/src/linux-rpi-vanilla/.git --work-tree=/usr/src/linux-rpi-vanilla checkout rpi-4.9.y

        if [ -f /etc/kernels/kernel-config-arm ]; then
            cp /etc/kernels/kernel-config-arm /usr/src/linux-rpi-vanilla/.config
        fi
    fi

    nproc=$(nproc)
    pwd=$(pwd)
    if [ ! -d /usr/src/linux-rpi-vanilla ]; then
        printf "error: no sources found in /usr/src/linux-rpi-vanilla"
        return 1
    fi
    cd /usr/src/linux-rpi-vanilla
    if prompt_input_yN "make bcm2709_defconfig"; then
        make -j${nproc} \
        ARCH=arm \
        CROSS_COMPILE=${CTARGET}- \
        bcm2709_defconfig
    fi

    if prompt_input_yN "make menuconfig"; then
        make -j${nproc} \
        ARCH=arm \
        CROSS_COMPILE=${CTARGET}- \
        MENUCONFIG_COLOR=mono \
        menuconfig
    fi

    if prompt_input_yN "build kernel"; then
        make -j${nproc} \
        ARCH=arm \
        CROSS_COMPILE=${CTARGET}- \
        zImage dtbs modules

        make -j${nproc} \
        ARCH=arm \
        CROSS_COMPILE=${CTARGET}- \
        INSTALL_MOD_PATH=${SYSROOT} \
        modules_install

        mkdir -p ${SYSROOT}/boot/overlays
        cp arch/arm/boot/dts/*.dtb ${SYSROOT}/boot/
        cp arch/arm/boot/dts/overlays/*.dtb* ${SYSROOT}/boot/overlays/
        cp arch/arm/boot/dts/overlays/README ${SYSROOT}/boot/overlays/
        scripts/mkknlimg arch/arm/boot/zImage ${SYSROOT}/boot/kernel7.img

        if prompt_input_yN "save new kernel config to /etc/kernels"; then
            cp .config /etc/kernels/kernel-config-arm
        fi
    fi
    cd ${pwd}

    if prompt_input_yN "copy non-free firmware for brcm"; then
        if [ ! -d /usr/src/firmware-nonfree ]; then
            git clone --depth 1 https://github.com/RPi-Distro/firmware-nonfree /usr/src/firmware-nonfree
        fi
        git --git-dir=/usr/src/firmware-nonfree/.git --work-tree=/usr/src/linux-rpi-vanilla pull origin \
        mkdir -p ${SYSROOT}/lib/firmware/brcm
        find /usr/src/firmware-nonfree/ -name 'brcmfmac43430-sdio.*' -exec cp {} ${SYSROOT}/lib/firmware/brcm/ \;
    fi

    if prompt_input_yN "build initramfs"; then
        rm -f ${SYSROOT}/boot/*initramfs*
        rsync -avr --delete /usr/src/linux-rpi-vanilla/ ${SYSROOT}/usr/src/linux-rpi-vanilla/
        [ -L ${SYSROOT}/usr/src/linux ] && unlink ${SYSROOT}/usr/src/linux
        ln -s linux-rpi-vanilla ${SYSROOT}/usr/src/linux
        sed -e 's/#SSH="no"/SSH="YES"/g' ${SYSROOT}/etc/genkernel.conf > ${SYSROOT}/etc/genkernel.conf.
        mv ${SYSROOT}/etc/genkernel.conf. ${SYSROOT}/etc/genkernel.conf
        chroot ${SYSROOT} /bin/sh -c "genkernel --no-mountboot --lvm --luks --kernel-config=/usr/src/linux/.config initramfs"
        initramfs=$(ls ${SYSROOT}/boot | grep initramfs)
        printf "initramfs ${initramfs} followkernel" > ${SYSROOT}/boot/config.txt
    fi

    if prompt_input_yN "wipe and randomize ${SDCARD} bits"; then
        dd if=/dev/urandom of=${SDCARD} bs=1M status=progress
    fi

    if prompt_input_yN "write partition scheme to ${SDCARD}"; then
        if [ "$(mount | grep ${SDCARD})" != "" ]; then
            umount -Rl ${SDCARD}
        fi
        sfdisk --no-reread --wipe always ${SDCARD} << EOF
label: dos
unit: sectors
${SDCARD}p1 : start=        2048, size=     1048576, type=c
${SDCARD}p2 : start=     1050624, type=83
EOF
    fi

    if prompt_input_yN "format ${SDCARD}"; then
        cryptsetup luksFormat ${SDCARD}p2
        cryptsetup luksOpen ${SDCARD}p2 rpi

        pvcreate /dev/mapper/rpi
        vgcreate rpi /dev/mapper/rpi
        lvcreate --size 2GB --name swap rpi
        lvcreate --extents 95%FREE --name root rpi

        mkswap -L "swap" /dev/mapper/rpi-swap
        mkfs.ext4 /dev/mapper/rpi-root
        mkfs.vfat ${SDCARD}p1
    fi

    if prompt_input_yN "deploy ${SYSROOT} to ${SDCARD}"; then
        if [ "$(cryptsetup status rpi | grep 'is active')" = "" ]; then
            cryptsetup luksOpen ${SDCARD}p2 rpi
            if [ $? -ne 0 ]; then
                printf "error: could not open ${SDCARD}p2 luks partition"
                return 1
            fi
            vgchange --available y rpi
            if [ $? -ne 0 ]; then
                printf "error: could not make volumes available"
            fi
        fi

        mkdir -p /mnt/rpi
        mount /dev/mapper/rpi-root /mnt/rpi
        mkdir -p /mnt/rpi/boot
        mount ${SDCARD}p1 /mnt/rpi/boot
        umount -Rl ${SYSROOT}/{proc,sys,dev}

        SDCARD_BOOT_UUID=$(blkid -s UUID -o value ${SDCARD}p1)
        if [ "$(grep boot /etc/fstab)" = "" ]; then
            printf "UUID=${SDCARD_BOOT_UUID}          /boot           vfat            noauto,noatime  2 2" >> ${SYSROOT}/etc/fstab
        fi

        SDCARD_ROOT_UUID=$(blkid -s UUID -o value ${SDCARD}p2)
        printf "ro crypt_root=UUID=${SDCARD_ROOT_UUID} real_root=/dev/mapper/rpi-root dolvm rootfstype=ext4" > ${SYSROOT}/boot/cmdline.txt
        #printf "ro dwc_otg.lpm_enable=0 console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 console=tty1 crypt_root=UUID=${SDCARD_ROOT_UUID} root=/dev/mapper/rpi-root dolvm rootfstype=ext4 elevator=deadline rootwait" > ${SYSROOT}/boot/cmdline.txt

        if prompt_input_yN "use --delete on rsync for ${SDCARD} files"; then
            RSYNC_DELETE=--delete
        fi
        rsync -avr --exclude ${RSYNC_DELETE} "var/git/*" ${SYSROOT}/ /mnt/rpi/

        umount /mnt/rpi/boot
        umount /mnt/rpi
        vgchange --available n rpi
        cryptsetup luksClose rpi
    fi
}

