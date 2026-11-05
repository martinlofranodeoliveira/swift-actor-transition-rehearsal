FROM swift:6.2-noble@sha256:22edf4bb29f6d43ad77bfdb1757666992d63a50ab124c41176f8c8c44ab69855
LABEL org.lofranotecnologia.atr.base="swift:6.2-noble@sha256:22edf4bb29f6d43ad77bfdb1757666992d63a50ab124c41176f8c8c44ab69855"
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /workspace /scratch && chown 1000:1000 /workspace /scratch
ENV HOME=/tmp SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swift-module-cache CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache
WORKDIR /workspace
USER 1000:1000
