# Minimal, production-leaning image for the Orbits relay server.
# Build:  docker build -t orbits-relay ./relay-server
# Run:    docker run -p 8080:8080 orbits-relay
FROM node:20-alpine

WORKDIR /app

# Install production deps only, from the lockfile, for reproducible builds.
COPY package.json package-lock.json* ./
RUN npm install --omit=dev --no-audit --no-fund

COPY src ./src

ENV PORT=8080
EXPOSE 8080

# Run as the built-in non-root user.
USER node

CMD ["node", "src/server.js"]
