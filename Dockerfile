# Build stage: compile wsgate and process webroot assets on the freerdp-build agent.
FROM antanoio/jenkins-agent-freerdp:1.0.0 AS builder

WORKDIR /build

# Cache dependency layer: only re-run cmake/make if source files change.
COPY CMakeLists.txt wsgate_main.cpp wsgate.hpp wsgateEHS.hpp wsgateEHS.cpp
COPY RDP.hpp RDP.cpp Primary.hpp Primary.cpp Update.hpp Update.cpp
COPY rdpcommon.hpp wshandler.hpp wshandler.cpp
COPY myrawsocket.hpp myrawsocket.cpp wsendpoint.hpp wsendpoint.cpp
COPY wsframe.hpp wsutf8.hpp common.hpp
COPY logging.hpp logging.cpp btexception.hpp btexception.cpp
COPY base64.hpp base64.cpp sha1.hpp sha1.cpp
COPY Png.hpp Png.cpp nova_token_auth.hpp nova_token_auth.cpp
COPY myBindHelper.hpp myBindHelper.cpp bindhelper.c
COPY config.h.cmake
COPY cmake/ cmake/
COPY webroot/ webroot/
COPY wsgate.ini.sample.in

RUN mkdir -p build \
    && cd build \
    && cmake .. \
    && make -j$(nproc)

# Runtime stage: minimal Ubuntu with only the binary and its runtime libraries.
FROM ubuntu:22.04

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        libssl3 \
        libpng16-16 \
        libboost-filesystem1.74.0 \
        libboost-system1.74.0 \
        libboost-regex1.74.0 \
        libboost-program-options1.74.0 \
    && rm -rf /var/lib/apt/lists/*

# FreeRDP, WinPR, EHS and CppRestSDK shared libraries from the builder stage.
COPY --from=builder /usr/lib/x86_64-linux-gnu/libfreerdp.so* /usr/lib/x86_64-linux-gnu/
COPY --from=builder /usr/lib/x86_64-linux-gnu/libwinpr.so*   /usr/lib/x86_64-linux-gnu/
COPY --from=builder /usr/lib/x86_64-linux-gnu/libehs.so*     /usr/lib/x86_64-linux-gnu/
COPY --from=builder /usr/lib/x86_64-linux-gnu/libcpprest.so* /usr/lib/x86_64-linux-gnu/

# wsgate binary and webroot.
COPY --from=builder /build/build/wsgate /usr/sbin/wsgate
COPY --from=builder /build/webroot    /usr/share/wsgate/webroot

# Default config; override at runtime with -c or mount a Secret here.
COPY wsgate.ini.sample.in /etc/wsgate/wsgate.ini

RUN mkdir -p /var/run/wsgate && ldconfig

EXPOSE 8080 8443

ENTRYPOINT ["/usr/sbin/wsgate"]
CMD ["-c", "/etc/wsgate/wsgate.ini"]
