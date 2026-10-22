FROM node:24-bookworm-slim
WORKDIR /app
COPY services/api/ ./
ENV NODE_ENV=production PORT=8080 DATA_DIR=/data
EXPOSE 8080
CMD ["node", "server.mjs"]
