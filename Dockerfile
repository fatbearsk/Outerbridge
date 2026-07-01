# Build:
# docker build --no-cache -t outerbridge .
#
# Run:
# docker run -d -p 3000:3000 outerbridge

ARG NODE_VERSION=22-bookworm-slim
FROM node:${NODE_VERSION}

WORKDIR /usr/src/packages

ENV CI=true
ENV NODE_ENV=development
ENV PORT=3000
ENV HOST=0.0.0.0
ENV HOSTNAME=0.0.0.0
ENV NPM_CONFIG_ENGINE_STRICT=false
ENV YARN_IGNORE_ENGINES=true
ENV PNPM_CONFIG_ENGINE_STRICT=false

# Native deps cover node-gyp, old packages, git dependencies, etc.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    git \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Make package managers available.
# Yarn classic is included for older monorepos.
RUN corepack enable || true \
  && npm config set fund false \
  && npm config set audit false \
  && npm config set engine-strict false \
  && npm install -g yarn@1.22.22 pnpm serve

# Copy everything first.
# This intentionally avoids failing on:
# COPY yarn.lock ./ -> no such file or directory
COPY . .

# Install dependencies intelligently:
# - pnpm if pnpm-lock.yaml exists
# - yarn if yarn.lock exists or workspaces suggest old Yarn monorepo
# - npm if package-lock.json exists
# - fallback to npm
# It also ignores engines and falls back when lockfiles are stale.
RUN set -eux; \
  if [ ! -f package.json ]; then \
    echo "ERROR: package.json not found at repo root"; \
    find . -maxdepth 3 -name package.json -print; \
    exit 1; \
  fi; \
  if [ -f pnpm-lock.yaml ]; then \
    PM="pnpm"; \
  elif [ -f yarn.lock ]; then \
    PM="yarn"; \
  elif [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then \
    PM="npm"; \
  elif node -e "const p=require('./package.json'); process.exit(p.packageManager && p.packageManager.startsWith('pnpm') ? 0 : 1)" >/dev/null 2>&1; then \
    PM="pnpm"; \
  elif node -e "const p=require('./package.json'); process.exit(p.packageManager && p.packageManager.startsWith('yarn') ? 0 : 1)" >/dev/null 2>&1; then \
    PM="yarn"; \
  elif node -e "const p=require('./package.json'); process.exit(p.workspaces ? 0 : 1)" >/dev/null 2>&1; then \
    PM="yarn"; \
  else \
    PM="npm"; \
  fi; \
  echo "$PM" > /tmp/package-manager; \
  echo "Using package manager: $PM"; \
  case "$PM" in \
    yarn) \
      yarn config set ignore-engines true || true; \
      if [ -f yarn.lock ]; then \
        yarn install --frozen-lockfile --non-interactive --ignore-engines \
        || yarn install --non-interactive --ignore-engines; \
      else \
        yarn install --non-interactive --ignore-engines; \
      fi \
      ;; \
    pnpm) \
      pnpm config set engine-strict false || true; \
      if [ -f pnpm-lock.yaml ]; then \
        pnpm install --frozen-lockfile --config.engine-strict=false \
        || pnpm install --no-frozen-lockfile --config.engine-strict=false; \
      else \
        pnpm install --no-frozen-lockfile --config.engine-strict=false; \
      fi \
      ;; \
    npm) \
      npm config set engine-strict false; \
      if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then \
        npm ci --legacy-peer-deps \
        || npm install --legacy-peer-deps; \
      else \
        npm install --legacy-peer-deps; \
      fi \
      ;; \
  esac

# Build if there is a build script.
# If there is no build script, don't fail the deployment.
RUN set -eux; \
  PM="$(cat /tmp/package-manager)"; \
  if node -e "const p=require('./package.json'); process.exit(p.scripts && p.scripts.build ? 0 : 1)" >/dev/null 2>&1; then \
    echo "Running root build script"; \
    case "$PM" in \
      yarn) yarn build ;; \
      pnpm) pnpm run build ;; \
      npm) npm run build ;; \
    esac; \
  elif [ -f packages/server/package.json ] && node -e "const p=require('./packages/server/package.json'); process.exit(p.scripts && p.scripts.build ? 0 : 1)" >/dev/null 2>&1; then \
    echo "Running packages/server build script"; \
    cd packages/server; \
    case "$PM" in \
      yarn) yarn build ;; \
      pnpm) pnpm run build ;; \
      npm) npm run build ;; \
    esac; \
  else \
    echo "No build script found; skipping build."; \
  fi

# Runtime should be production.
ENV NODE_ENV=production

EXPOSE 3000

# Start intelligently:
# 1. root start script
# 2. packages/server start script
# 3. common Node entry files
# 4. static build folders
CMD ["bash", "-lc", "set -e; PM=$(cat /tmp/package-manager 2>/dev/null || echo npm); export PORT=${PORT:-3000}; export HOST=${HOST:-0.0.0.0}; export HOSTNAME=${HOSTNAME:-0.0.0.0}; if node -e \"const p=require('./package.json'); process.exit(p.scripts && p.scripts.start ? 0 : 1)\" >/dev/null 2>&1; then case \"$PM\" in yarn) exec yarn start ;; pnpm) exec pnpm run start ;; npm) exec npm run start ;; esac; elif [ -f packages/server/package.json ] && node -e \"const p=require('./packages/server/package.json'); process.exit(p.scripts && p.scripts.start ? 0 : 1)\" >/dev/null 2>&1; then cd packages/server; case \"$PM\" in yarn) exec yarn start ;; pnpm) exec pnpm run start ;; npm) exec npm run start ;; esac; elif [ -f server.js ]; then exec node server.js; elif [ -f index.js ]; then exec node index.js; elif [ -f packages/server/server.js ]; then cd packages/server && exec node server.js; elif [ -f packages/server/index.js ]; then cd packages/server && exec node index.js; elif [ -d dist ]; then exec serve -s dist -l ${PORT}; elif [ -d build ]; then exec serve -s build -l ${PORT}; elif [ -d public ]; then exec serve -s public -l ${PORT}; else echo 'ERROR: no start target found'; find . -maxdepth 4 -type f \\( -name package.json -o -name server.js -o -name index.js \\) | sort; exit 1; fi"]
