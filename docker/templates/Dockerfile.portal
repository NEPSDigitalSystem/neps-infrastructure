FROM node:20-alpine

WORKDIR /app
RUN addgroup -g 1001 -S neps && adduser -S neps -u 1001

COPY package*.json ./
RUN npm ci

COPY . .
RUN chown -R neps:neps /app
USER neps

EXPOSE 3000
CMD ["npm", "run", "dev"]
