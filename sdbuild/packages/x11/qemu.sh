#! /bin/bash

set -x
set -e

. /etc/environment
for f in /etc/profile.d/*.sh; do source $f; done

if [ ${ARCH} == 'arm' ]; then
    export PKG_CONFIG_PATH=/usr/lib/arm-linux-gnueabihf/pkgconfig
else
    export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig
fi

if [ -f /home/xilinx/Welcome\ to\ Pynq.ipynb ]; then
	jupyter nbconvert --to html \
	/home/xilinx/Welcome\ to\ Pynq.ipynb
	rm -f /home/xilinx/Welcome\ to\ Pynq.ipynb
fi

systemctl enable pynq-x11.service
systemctl set-default multi-user

echo startfluxbox > /root/.xinitrc

mkdir /root/armsoc_build
cd /root/armsoc_build

# freedesktop retired anongit; the driver lives on gitlab.freedesktop.org now.
# The old host stopped answering (connection times out after ~2 min), which is
# also why this used to need -c http.sslverify=false.
git clone https://gitlab.freedesktop.org/xorg/driver/xf86-video-armsoc.git
cd xf86-video-armsoc
git apply /armsoc.patch --ignore-whitespace
git apply /pixmap.patch --ignore-whitespace
./autogen.sh
./configure --prefix=/usr
make -j4
make install
cd /
rm -rf /root/armsoc_build
rm /armsoc.patch
rm /pixmap.patch
