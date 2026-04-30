FROM ghcr.io/openclaw/openclaw:2026.4.26

USER root

# Install Codex CLI globally (version pinned)
RUN npm install -g @openai/codex@0.125.0 \
    && npm cache clean --force

# Ensure codex is on PATH for login shell (OpenClaw uses sh -lc)
RUN echo 'export PATH="/usr/local/bin:$PATH"' > /etc/profile.d/codex-path.sh

# Pre-create dirs so named volumes inherit node ownership
RUN mkdir -p /home/node/.codex /home/node/.openclaw/plugin-runtime-deps \
    && chown node:node /home/node/.codex /home/node/.openclaw/plugin-runtime-deps

# Add entrypoint script
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

USER node

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured", "--bind", "lan"]
