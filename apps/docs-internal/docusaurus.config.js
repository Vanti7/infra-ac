// @ts-check
const {themes: prismThemes} = require('prism-react-renderer');

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'aetheriscloud — Ops',
  tagline: 'Documentation interne infra',
  favicon: 'img/favicon.png',

  url: 'https://docs-internal.ops.aetheriscloud.fr',
  baseUrl: '/',

  organizationName: 'aetheriscloud',
  projectName: 'docs-internal',

  onBrokenLinks: 'warn',
  onBrokenMarkdownLinks: 'warn',

  // Les docs racine (plan/workflow/disaster-recovery) sont de la prose technique
  // brute (ex: "cert <15j", "disque >80%") — pas du JSX. `.md` = markdown pur,
  // MDX réservé aux fichiers `.mdx` explicites. Sans ça, le build casse sur tout
  // `<` suivi d'un chiffre (interprété comme un tag JSX invalide).
  markdown: {
    format: 'detect',
  },

  i18n: {
    defaultLocale: 'fr',
    locales: ['fr'],
  },

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          sidebarPath: require.resolve('./sidebars.js'),
          routeBasePath: 'docs',
          editUrl: undefined,
        },
        blog: false,
        theme: {
          customCss: require.resolve('./src/css/custom.css'),
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      colorMode: {
        respectPrefersColorScheme: true,
      },
      navbar: {
        title: 'aetheriscloud Ops',
        items: [
          {
            type: 'docSidebar',
            sidebarId: 'opsSidebar',
            position: 'left',
            label: 'Documentation',
          },
        ],
      },
      footer: {
        style: 'dark',
        copyright: `Accès réservé — infra aetheriscloud`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
      },
    }),
};

module.exports = config;
