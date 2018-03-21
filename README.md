# sysroot

These scripts are used on Funtoo to automate the boring task of setting up a Raspberry Pi 3 cross environment and a full working sysroot with a custom kernel build that can be easily deployed on a SD card.

Review the variables on the script and, for the first time running it, you should answer 'y' for every question:

./sysroot-install

This creates a sysroot on the default path /home/sysroots/armv7a-hardfloat-linux-gnueabi and you can use sysroot-chroot to grab a shell inside it:

./sysroot-chroot /home/sysroots/armv7a-hardfloat-linux-gnueabi

The third script, sysroot-mount, is a dependency for both.
