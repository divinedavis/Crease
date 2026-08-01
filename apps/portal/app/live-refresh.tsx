'use client';

import { createBrowserClient } from '@supabase/ssr';
import { useEffect } from 'react';
import { useRouter } from 'next/navigation';

/**
 * Keeps the queue current without anyone pressing refresh.
 *
 * Couriers move while the tablet sits on the counter, so a stale board is a
 * shop pulling the wrong bag. Realtime pushes tell us *that* something moved;
 * the actual re-read goes through the server so RLS still decides what this
 * shop is allowed to see.
 */
export function LiveRefresh({ cleanerIds }: { cleanerIds: string[] }) {
  const router = useRouter();

  useEffect(() => {
    if (cleanerIds.length === 0) return;

    const supabase = createBrowserClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    );

    const channel = supabase
      .channel('portal-orders')
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'orders',
          filter: `cleaner_id=in.(${cleanerIds.join(',')})`,
        },
        () => router.refresh(),
      )
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'delivery_legs' },
        () => router.refresh(),
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
  }, [cleanerIds.join(','), router]);

  return null;
}
