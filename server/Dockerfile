FROM node:22-alpine
WORKDIR /srv
COPY server.mjs ./server.mjs
ENV PORT=8080
EXPOSE 8080
USER node
CMD ["node", "server.mjs"]
