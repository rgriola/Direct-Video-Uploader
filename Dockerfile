# Stage 1: Build the Admin Frontend
FROM node:22-slim AS admin-build
WORKDIR /app/admin
# Install dependencies
COPY admin/package*.json ./
RUN npm ci --include=dev
# Copy admin source code
COPY admin/ ./
# Build the Vite admin project
RUN npm run build

# Stage 2: Build the Server and Final Image
FROM node:22-slim AS server-build
# Install OpenSSL for Prisma and ca-certificates
RUN apt-get update -y && apt-get install -y openssl ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app
# Set production environment
ENV NODE_ENV=production

# Copy server dependencies
COPY server/package*.json ./server/
WORKDIR /app/server
RUN npm ci --omit=dev

# Copy server source code and prisma schema
COPY server/ ./

# Generate Prisma Client
RUN npx prisma generate

# Copy the built admin dashboard from the admin-build stage into the server's public folder
COPY --from=admin-build /app/server/public ./public/

# Expose port (Cloud Run defaults to 8080 or respects PORT env var, Fastify uses PORT)
ENV PORT=3000
EXPOSE 3000

# Start the Fastify server
CMD ["node", "src/index.js"]
