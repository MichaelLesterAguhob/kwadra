FROM node:22-bookworm-slim AS build
WORKDIR /app/kwadra-backend-api
COPY kwadra-backend-api/package.json kwadra-backend-api/package-lock.json ./
RUN npm ci
COPY kwadra-backend-api/tsconfig*.json ./
COPY kwadra-backend-api/src ./src
RUN npx tsc -p tsconfig.build.json && npm prune --omit=dev

FROM node:22-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app/kwadra-backend-api
COPY --from=build /app/kwadra-backend-api/node_modules ./node_modules
COPY --from=build /app/kwadra-backend-api/dist ./dist
COPY kwadra-backend-api/package.json ./package.json
COPY kwadra-backend-api/migrations ./migrations
COPY apps/management/build/web /app/apps/management/build/web
COPY apps/management/assets/images /app/apps/management/assets/images
COPY apps/management/assets/branding /app/apps/management/assets/branding
COPY apps/marketplace/public /app/apps/marketplace/public
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=7s --start-period=30s CMD node -e "fetch('http://127.0.0.1:3000/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node","dist/server.js"]
