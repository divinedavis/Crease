import './globals.css';
import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Crease — cleaner portal',
  description: 'Intake, pricing and return dispatch for partner cleaners.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
