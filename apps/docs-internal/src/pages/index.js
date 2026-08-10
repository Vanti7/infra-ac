import React from 'react';
import Layout from '@theme/Layout';
import Link from '@docusaurus/Link';

const docs = [
  {
    href: '/docs/plan-deploiement-dedibox',
    title: 'Plan de déploiement',
    description: "Le plan complet, phase par phase, pour la dedibox aetheriscloud.",
  },
  {
    href: '/docs/workflow-deploiement-dedibox',
    title: 'Suivi de déploiement',
    description: "État réel d'avancement, écarts au plan, bugs rencontrés et corrigés.",
  },
  {
    href: '/docs/disaster-recovery',
    title: 'Reprise après sinistre',
    description: "Procédure de reconstruction complète si l'hôte Proxmox est perdu.",
  },
  {
    href: '/docs/exploitation',
    title: 'Exploitation — tâches courantes',
    description: "Accès rapides, secrets ksops, onboarding client, resync ArgoCD.",
  },
];

export default function Home() {
  return (
    <Layout
      title="aetheriscloud — Ops"
      description="Documentation interne infra aetheriscloud">
      <main style={{maxWidth: 720, margin: '0 auto', padding: '3rem 1.5rem'}}>
        <h1>Documentation interne aetheriscloud</h1>
        <p>Accès réservé à l'équipe infra — ne pas partager ces pages en dehors.</p>
        <div style={{display: 'flex', flexDirection: 'column', gap: '1rem', marginTop: '2rem'}}>
          {docs.map((doc) => (
            <Link
              key={doc.href}
              to={doc.href}
              style={{
                display: 'block',
                padding: '1.25rem',
                borderRadius: 8,
                border: '1px solid var(--ifm-color-emphasis-300)',
                textDecoration: 'none',
              }}>
              <strong style={{fontSize: '1.1rem'}}>{doc.title}</strong>
              <p style={{margin: '0.4rem 0 0', color: 'var(--ifm-color-emphasis-700)'}}>
                {doc.description}
              </p>
            </Link>
          ))}
        </div>
      </main>
    </Layout>
  );
}
