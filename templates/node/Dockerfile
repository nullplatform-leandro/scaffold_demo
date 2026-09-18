# Replaces the Dockerfile the repository inherited from the "Any technology"
# template, which ran an http-echo image. That one has to go: the CI that came
# with the same template builds whatever Dockerfile is at the root and pushes it
# as the docker-image asset, so leaving it in place would deploy the echo server
# no matter what else the scaffolding wrote.

FROM node:22-alpine

WORKDIR /app

# No `npm ci` layer, because there are no dependencies to resolve. package.json is
# copied for the metadata, not for an install step -- which is also why the CI
# that came with the template needs no change to build this.
COPY package.json ./
COPY src/ src/

# node:22-alpine ships a non-root `node` user already; there is no reason for the
# application to be the one thing in the image running as root.
USER node

# 8080, because that is the port the "Any technology" template exposed and the one
# the scope health-checks.
ENV PORT=8080
EXPOSE 8080

CMD ["node", "src/server.js"]
