# Build stage: compile wsgate and process webroot assets on the freerdp-build agent.
FROM antanoio/jenkins-agent-freerdp:1.0.0 AS builder

USER root

WORKDIR /build

# The wsgate source tree lives in the wsgate/ subdirectory of this repository.
COPY wsgate/ wsgate/
COPY kubernetes/ kubernetes/

# The agent image runs as uid 1000; make the checkout writable.
RUN chown -R 1000:1000 /build

RUN cd wsgate \
    && rm -rf build \
    && mkdir -p build \
    && cd build \
    && cmake -DHAVE_CPLUSPLUS11=ON \
            -DCMAKE_C_FLAGS="-Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types" \
            -DCMAKE_CXX_FLAGS="-std=c++11 -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types" \
            .. \
    && make -j$(nproc)

# Runtime stage: minimal Debian with only the binary and its runtime libraries.
# Must match the builder's glibc (Debian 13) or the binary won't load.
FROM debian:13-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        libssl3t64 \
        libpng16-16t64 \
        libbrotli1 \
    && rm -rf /var/lib/apt/lists/*

# FreeRDP + WinPR shared libraries (split per module, depend on OpenSSL 1.1.1).
COPY --from=builder /usr/lib/x86_64-linux-gnu/libfreerdp*.so* /usr/lib/x86_64-linux-gnu/
COPY --from=builder /usr/lib/x86_64-linux-gnu/libwinpr*.so*   /usr/lib/x86_64-linux-gnu/

# CppRestSDK (Casablanca) - links against the system OpenSSL 3.0 (libssl3 above).
COPY --from=builder /usr/lib/x86_64-linux-gnu/libcpprest*.so* /usr/lib/x86_64-linux-gnu/

# Boost shared libs - the builder is Debian 13 (Boost 1.83), runtime is Ubuntu
# 22.04 (Boost 1.74), so copy the exact SONAME from the builder.
COPY --from=builder /usr/lib/x86_64-linux-gnu/libboost_*.so* /usr/lib/x86_64-linux-gnu/

# OpenSSL 1.1.1 - required by FreeRDP/WinPR at runtime (built in the agent image).
COPY --from=builder /opt/openssl-1.1.1/lib/libssl.so.1.1*    /usr/lib/x86_64-linux-gnu/
COPY --from=builder /opt/openssl-1.1.1/lib/libcrypto.so.1.1* /usr/lib/x86_64-linux-gnu/

# wsgate binary and processed webroot (CMake strips the -debug assets).
COPY --from=builder /build/wsgate/build/wsgate /usr/sbin/wsgate
COPY --from=builder /build/wsgate/build/webroot /usr/share/wsgate/webroot

# Default config; override at runtime with -c or mount a Secret here.
COPY wsgate/wsgate.ini.sample.in /etc/wsgate/wsgate.ini

RUN mkdir -p /var/run/wsgate && ldconfig

EXPOSE 8080 8443

ENTRYPOINT ["/usr/sbin/wsgate"]
CMD ["-c", "/etc/wsgate/wsgate.ini"]
