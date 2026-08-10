#!/usr/bin/env python3
"""Synchronise kubernetes/tenants/*.values.yaml vers NetBox (tenant + namespace).

Déclenché par le job CI `sync-netbox` à chaque merge sur `kubernetes/tenants/`.
Un fichier `<name>.values.yaml` avec `name: <name>` devient un Tenant NetBox
`<name>` dont le custom field `namespace` vaut `cust-<name>` (convention du
chart onboarding-client, cf. kubernetes/tenants/onboarding-client/templates/namespace.yaml).
"""

import glob
import os
import sys

import pynetbox
import yaml

NETBOX_URL = os.environ["NETBOX_URL"]
NETBOX_TOKEN = os.environ["NETBOX_TOKEN"]
TENANTS_GLOB = os.path.join(os.path.dirname(__file__), "..", "kubernetes", "tenants", "*.values.yaml")


def main() -> int:
    nb = pynetbox.api(NETBOX_URL, token=NETBOX_TOKEN)

    files = sorted(glob.glob(TENANTS_GLOB))
    if not files:
        print("Aucun fichier tenants/*.values.yaml trouvé, rien à faire.")
        return 0

    for path in files:
        with open(path) as f:
            values = yaml.safe_load(f) or {}

        name = values.get("name")
        if not name:
            print(f"⚠️  {path} : pas de champ 'name', ignoré.")
            continue

        namespace = f"cust-{name}"
        existing = nb.tenancy.tenants.get(slug=name)
        if existing:
            existing.update({"custom_fields": {"namespace": namespace}})
            print(f"✓ tenant '{name}' mis à jour (namespace={namespace})")
        else:
            nb.tenancy.tenants.create(
                name=name,
                slug=name,
                custom_fields={"namespace": namespace},
            )
            print(f"✓ tenant '{name}' créé (namespace={namespace})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
