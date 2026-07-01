# Build local monorepo image:
# docker build --no-cache -t outerbridge .
#
# Run image:
# docker run -d -p 3000:3000 outerbridge

FROM node:22-bookworm-slim

WORKDIR /usr/src/packages

ENV CI=true

# Copy the full repo first because this repo currently may not have yarn.lock.
# This avoids: COPY yarn.lock ./ -> no such file or directory
COPY . .

# Install dependencies.
# If yarn.lock exists, use frozen lockfile for reproducible installs.
# If it does not exist, fall back to normal yarn install so the build does not fail.
RUN if [ -f yarn.lock ]; then \
      yarn install --frozen-lockfile --non-interactive; \
    else \
      echo "warning: yarn.lock not found; running non-frozen yarn install"; \
      yarn install --non-interactive; \
    fi

# Build app
RUN yarn build

ENV NODE_ENV=production

EXPOSE 3000

CMD ["yarn", "start"]
