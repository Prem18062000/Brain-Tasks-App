# ====== BUILD STAGE ======
FROM node:18-alpine AS builder

# Set workdir
WORKDIR /app

# Install deps using package.json + lock file
COPY package*.json ./
RUN npm ci

# Copy source and build
COPY . .
RUN npm run build    # outputs to /app/dist

# ====== RUNTIME STAGE ======
FROM node:18-alpine AS runner

WORKDIR /usr/src/app

# We'll serve the built files using "serve" on port 3000
RUN npm install -g serve

# Copy built assets from the builder image
COPY --from=builder /app/dist ./dist

# Container listens on 3000
EXPOSE 3000

# Start HTTP server on port 3000
CMD ["serve", "-s", "dist", "-l", "3000"]
