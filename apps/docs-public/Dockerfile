# podman build -f apps/docs-public/Dockerfile -t docs-public:<tag> apps/docs-public

FROM docker.io/library/node:20-alpine AS build
WORKDIR /app

COPY package.json ./
RUN npm install

COPY . ./
RUN npm run build

FROM docker.io/nginxinc/nginx-unprivileged:1.27-alpine
COPY --from=build /app/build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
