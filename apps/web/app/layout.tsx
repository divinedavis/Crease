import type { Metadata, Viewport } from 'next';
import './globals.css';

export const metadata: Metadata = {
  metadataBase: new URL('https://creasenyc.com'),
  title: 'Crease — Dry cleaning, picked up and delivered',
  description:
    'A courier collects from your door, your neighborhood cleaner does the work, and everything comes back pressed. Live in Brooklyn — check your address.',
  openGraph: {
    title: 'Crease — Dry cleaning, picked up and delivered',
    description:
      'Book a pickup, your neighborhood cleaner does the work, and it comes back pressed. Live in Brooklyn.',
    url: 'https://usecreaseapp.com/',
    type: 'website',
  },
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
