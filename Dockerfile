# ============================================================
# Stage 1: Builder
# Compiles rAthena from source with all build dependencies
# ============================================================
FROM debian:bookworm-slim AS builder

ARG PACKETVER=20211103
ARG RATHENA_BRANCH=master

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    gcc \
    g++ \
    make \
    libmariadb-dev \
    libmariadb-dev-compat \
    zlib1g-dev \
    libpcre3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch ${RATHENA_BRANCH} \
    https://github.com/rathena/rathena.git .

RUN ./configure --enable-packetver=${PACKETVER} && \
    make clean && make server

# ============================================================
# Stage 2a: Login Server
# Minimal runtime image for the login-server process
# ============================================================
FROM debian:bookworm-slim AS login-server

RUN apt-get update && apt-get install -y --no-install-recommends \
    libmariadb3 \
    zlib1g \
    libpcre3 \
    netcat-openbsd \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1000 rathena && useradd -u 1000 -g rathena -m rathena

WORKDIR /rathena
COPY --from=builder /src/login-server ./
COPY --from=builder /src/conf ./conf
COPY --from=builder /src/db ./db
COPY docker/entrypoint-login.sh /entrypoint.sh
RUN mkdir -p /rathena/conf/generated && \
    chmod +x /entrypoint.sh && chown -R rathena:rathena /rathena

USER rathena
EXPOSE 6900
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD nc -z localhost 6900 || exit 1
ENTRYPOINT ["/entrypoint.sh"]

# ============================================================
# Stage 2b: Char Server
# Minimal runtime image for the char-server process
# ============================================================
FROM debian:bookworm-slim AS char-server

RUN apt-get update && apt-get install -y --no-install-recommends \
    libmariadb3 \
    zlib1g \
    libpcre3 \
    netcat-openbsd \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1000 rathena && useradd -u 1000 -g rathena -m rathena

WORKDIR /rathena
COPY --from=builder /src/char-server ./
COPY --from=builder /src/conf ./conf
COPY --from=builder /src/db ./db
COPY docker/entrypoint-char.sh /entrypoint.sh
RUN mkdir -p /rathena/conf/generated && \
    chmod +x /entrypoint.sh && chown -R rathena:rathena /rathena

USER rathena
EXPOSE 6121
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD nc -z localhost 6121 || exit 1
ENTRYPOINT ["/entrypoint.sh"]

# ============================================================
# Stage 2c: Map Server
# Minimal runtime image for the map-server process
# Includes npc/ directory for NPC scripts
# ============================================================
FROM debian:bookworm-slim AS map-server

RUN apt-get update && apt-get install -y --no-install-recommends \
    libmariadb3 \
    zlib1g \
    libpcre3 \
    netcat-openbsd \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1000 rathena && useradd -u 1000 -g rathena -m rathena

WORKDIR /rathena
COPY --from=builder /src/map-server ./
COPY --from=builder /src/conf ./conf
COPY --from=builder /src/db ./db
COPY --from=builder /src/npc ./npc
COPY docker/entrypoint-map.sh /entrypoint.sh
RUN mkdir -p /rathena/conf/generated && \
    chmod +x /entrypoint.sh && chown -R rathena:rathena /rathena

USER rathena
EXPOSE 5121
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD nc -z localhost 5121 || exit 1
ENTRYPOINT ["/entrypoint.sh"]
