import { useEffect, useRef, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { supabase } from '@/integrations/supabase/client';

/**
 * Silent poller: when user returns from OxaPay (?sub=success&order_id=oxs_...),
 * polls oxapay-sync-deposit until subscription is activated, then invalidates queries.
 * Renders nothing.
 */
export default function OxapaySubscriptionPoller() {
  const [searchParams, setSearchParams] = useSearchParams();
  const queryClient = useQueryClient();
  const polledRef = useRef<string | null>(null);
  const [, setTick] = useState(0);

  useEffect(() => {
    const sub = searchParams.get('sub');
    const orderId = searchParams.get('order_id');
    if (!sub || !orderId || !orderId.startsWith('oxs_')) return;
    if (polledRef.current === orderId) return;
    polledRef.current = orderId;

    let cancelled = false;
    const toastId = `oxs-${orderId}`;
    toast.loading('Verifying crypto payment…', { id: toastId });

    (async () => {
      const start = Date.now();
      const MAX_MS = 120_000;
      const INTERVAL = 4_000;

      while (!cancelled && Date.now() - start < MAX_MS) {
        try {
          const { data } = await supabase.functions.invoke('oxapay-sync-deposit', {
            body: { order_id: orderId },
          });
          if (data?.credited || data?.status === 'success') {
            toast.success('🎉 Subscription activated!', { id: toastId });
            await queryClient.invalidateQueries({ queryKey: ["subscription"] });
            await queryClient.invalidateQueries({ queryKey: ["user-subscription"] });
            await queryClient.invalidateQueries({ queryKey: ["wallet"] });
            await queryClient.invalidateQueries({ queryKey: ["transactions"] });
            await queryClient.invalidateQueries({ queryKey: ['subscription'] });
            await queryClient.invalidateQueries({ queryKey: ['user-subscription'] });
            clearParams();
            return;
          }
          if (data?.status === 'failed') {
            toast.error('Payment expired. Please try again.', { id: toastId });
            clearParams();
            return;
          }
        } catch (e: any) {
          console.error('sub sync error', e);
          toast.error(`Verification error: ${e?.message || 'network issue'}. Retrying…`, { id: toastId });
        }
        await new Promise((r) => setTimeout(r, INTERVAL));
        setTick((t) => t + 1);
      }
      toast.message('Still waiting for blockchain confirmation. It will activate automatically.', { id: toastId });
      clearParams();
    })();

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchParams]);

  function clearParams() {
    const next = new URLSearchParams(searchParams);
    next.delete('sub');
    next.delete('order_id');
    setSearchParams(next, { replace: true });
  }

  return null;
}
