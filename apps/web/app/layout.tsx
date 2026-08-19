import type { Metadata, Viewport } from 'next';
import './globals.css';

export const metadata: Metadata = {
  metadataBase: new URL('https://creasenyc.com'),
  title: 'Crease — Laundry, picked up and delivered in Brooklyn',
  description:
    'Wash & fold pickup and delivery in Brooklyn. $2.00 a pound, $20 minimum. A courier collects from your door and your neighborhood laundromat does the rest.',
  openGraph: {
    title: 'Crease — Laundry, picked up and delivered in Brooklyn',
    description:
      'Wash & fold pickup and delivery in Brooklyn. $2.00 a pound, $20 minimum.',
    url: 'https://creasenyc.com/',
    type: 'website',
  },
  alternates: { canonical: 'https://creasenyc.com/' },
  icons: { icon: '/assets/icon.svg' },
};

// Without this the page lays out at 980px on an iPhone and every phone visitor
// meets a desktop site shrunk to nothing.
export const viewport: Viewport = { width: 'device-width', initialScale: 1 };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
