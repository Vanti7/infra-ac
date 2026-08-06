import React from 'react';
import Layout from '@theme/Layout';
import Link from '@docusaurus/Link';

export default function Home() {
  return (
    <Layout
      title="aetheriscloud"
      description="Documentation aetheriscloud">
      <main
        style={{
          maxWidth: 720,
          margin: '0 auto',
          padding: '4rem 1.5rem',
          textAlign: 'center',
        }}>
        <h1>aetheriscloud</h1>
        <p style={{fontSize: '1.1rem', color: 'var(--ifm-color-emphasis-700)'}}>
          Documentation — contenu en cours de rédaction.
        </p>
        <Link
          className="button button--primary button--lg"
          to="/docs/intro"
          style={{marginTop: '1.5rem'}}>
          Voir la documentation
        </Link>
      </main>
    </Layout>
  );
}
