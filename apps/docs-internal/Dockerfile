# Build depuis la racine du repo (pas apps/docs-internal/) : ce site inclut par
# copie directe les 3 docs qui vivent à la racine (plan/workflow/disaster-recovery),
# symlinkées dans docs/ pour l'édition locale mais copiées en dur ici pour ne pas
# dépendre du comportement de COPY sur des symlinks qui sortent du contexte de build.
#
#   podman build -f apps/docs-internal/Dockerfile -t docs-internal:<tag> .

FROM docker.io/library/node:20-alpine AS build
WORKDIR /app

COPY apps/docs-internal/package.json ./
RUN npm install

COPY apps/docs-internal/ ./
COPY plan-deploiement-dedibox.md workflow-deploiement-dedibox.md disaster-recovery.md ./docs/

RUN npm run build

FROM docker.io/nginxinc/nginx-unprivileged:1.27-alpine
COPY --from=build /app/build /usr/share/nginx/html
COPY apps/docs-internal/nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
