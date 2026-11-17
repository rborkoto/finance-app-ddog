FROM node:20-alpine

# Create a non-root user — never run Finance services as root
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy manifests first so Docker layer-caches the install step
COPY package.json ./

# Production-only install — devDependencies (nodemon) are not needed in the image
RUN npm install --omit=dev

COPY src/ ./src/

# Drop privileges before starting the process
USER appuser

EXPOSE 8082

CMD ["node", "src/index.js"]
