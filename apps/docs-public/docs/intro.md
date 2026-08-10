# Introduction

Documentation technique aetheriscloud — comment fonctionne l'infrastructure mise à
votre disposition. Le reste (tarifs, contrat, contact) n'est pas couvert ici.

## Ce que vous recevez

Chaque client dispose d'un espace dédié et isolé sur le cluster Kubernetes
aetheriscloud :

- Un **namespace Kubernetes** qui vous est propre
- Des **quotas de ressources** réservés : 2 CPU / 4 Gio de mémoire garantis
  (extensibles jusqu'à 3 CPU / 6 Gio), 20 Gio de stockage, jusqu'à 30 pods et 5 volumes
- Une **isolation réseau** entre clients (NetworkPolicy) : votre espace ne peut ni voir
  ni être vu par celui d'un autre client
- Un accès **`kubectl`** scopé à votre seul namespace (droits `edit` : vous pouvez créer,
  modifier et supprimer vos propres ressources, pas celles de la plateforme)

## Authentification

L'accès à votre namespace passe par **Keycloak** (SSO) — pas de certificat client ni de
token à gérer vous-même. Votre compte est rattaché à un groupe qui détermine
exactement l'espace auquel vous avez accès, ni plus ni moins.

## En construction

Le détail pas-à-pas de la configuration `kubectl` côté client sera documenté ici au
fur et à mesure des premiers onboardings réels.
