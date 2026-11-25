FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential autoconf automake libtool libtool-bin pkg-config \
    libusb-1.0-0-dev libssl-dev python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Fetched by full SHA, not by branch: PR #3780 is still open, so its branch can
# be rebased or force-pushed and a short or symbolic ref would silently build
# something other than the revision verified on real hardware.
RUN git init /opt/nut \
    && cd /opt/nut \
    && git remote add origin https://github.com/reklrekl/nut.git \
    && git fetch --depth 1 origin 88948fb8c0ab5e2cfa92e6f832b613e0a2094f56 \
    && git checkout FETCH_HEAD \
    && ./autogen.sh \
    && ./configure --prefix=/opt/nut-install --with-usb=yes --with-drivers=usbhid-ups --with-doc=skip --without-cgi --without-snmp \
    && make -j4 \
    && make install

# DSM runs `killall upsd` every time UPS settings are applied, and it sees
# container processes, so a server named upsd is shot from outside the
# container. The driver is unaffected: its name does not match.
RUN mv /opt/nut-install/sbin/upsd /opt/nut-install/sbin/nut-upsd

COPY start.sh /start.sh
RUN chmod 755 /start.sh
CMD ["/bin/sh", "/start.sh"]
