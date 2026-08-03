import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useSubscription } from '@/hooks/useSubscription';
import { supabase } from '@/integrations/supabase/client';
import { toast } from 'sonner';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { SubscriptionRequestDialog } from './SubscriptionRequestDialog';
import {
  Lock,
  Zap,
  Crown,
  Clock,
  CheckCircle2,
  ArrowRight,
  Sparkles,
  Bitcoin,
  Loader2,
} from 'lucide-react';

interface SubscriptionCheckDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  initialPlan?: 'monthly' | 'yearly' | 'lifetime';
}

export function SubscriptionCheckDialog({ open, onOpenChange, initialPlan = 'yearly' }: SubscriptionCheckDialogProps) {
  const { hasPendingRequest } = useSubscription();
  const [showRequestDialog, setShowRequestDialog] = useState(false);
  const [selectedPlan, setSelectedPlan] = useState<'monthly' | 'yearly' | 'lifetime'>(initialPlan);
  // Sync when parent opens dialog with a different plan choice.
  useEffect(() => {
    if (open) setSelectedPlan(initialPlan);
  }, [open, initialPlan]);
  const [cryptoLoading, setCryptoLoading] = useState(false);

  async function payWithCrypto() {
    setCryptoLoading(true);
    try {
      const { data, error } = await supabase.functions.invoke('oxapay-create-subscription', {
        body: { plan: selectedPlan },
      });
      if (error) throw error;
      if (!data?.payment_url) throw new Error(data?.error || 'No payment URL');
      window.location.href = data.payment_url;
    } catch (e: any) {
      console.error(e);
      toast.error(e?.message || 'Could not start crypto payment');
      setCryptoLoading(false);
    }
  }

  return (
    <>
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <div className="w-10 h-10 rounded-full bg-primary/10 border border-primary/30 flex items-center justify-center">
                <Lock className="h-5 w-5 text-primary" />
              </div>
              Subscription Required
            </DialogTitle>
            <DialogDescription>
              Choose a plan to start placing orders and unlock all features.
            </DialogDescription>
          </DialogHeader>

          <div className="flex items-center gap-2.5 px-4 py-2.5 rounded-xl bg-[#60a5fa]/10 border border-[#60a5fa]/20">
            <Sparkles className="h-4 w-4 text-[#60a5fa] shrink-0" />
            <p className="text-sm font-semibold text-foreground/80">
              🚀 High-performance Organic Growth for Serious Builders.
            </p>
          </div>

          <div className="py-2">
            {/* Pending Request Notice */}
            {hasPendingRequest && (
              <div className="mb-4 p-4 rounded-xl bg-warning/10 border border-warning/30">
                <div className="flex items-center gap-3">
                  <Clock className="h-5 w-5 text-warning" />
                  <div>
                    <p className="font-medium text-warning">Request Pending</p>
                    <p className="text-sm text-foreground/80">
                      Your subscription request is being reviewed. We'll contact you soon!
                    </p>
                  </div>
                </div>
              </div>
            )}

            {/* Pricing Cards */}
            {!hasPendingRequest && (
              <div className="grid grid-cols-3 gap-2 mb-4">
                {/* Monthly Plan */}
                <div
                  className={`p-3 rounded-xl border-2 cursor-pointer transition-all ${selectedPlan === 'monthly'
                    ? 'border-primary bg-primary/5'
                    : 'border-border hover:border-primary/50'
                    }`}
                  onClick={() => setSelectedPlan('monthly')}
                >
                  <div className="flex items-center justify-between mb-1.5">
                    <div className="w-7 h-7 rounded-full bg-primary/10 flex items-center justify-center">
                      <Zap className="h-3.5 w-3.5 text-primary" />
                    </div>
                    {selectedPlan === 'monthly' && (
                      <CheckCircle2 className="h-3.5 w-3.5 text-primary" />
                    )}
                  </div>
                  <h3 className="font-semibold text-xs mb-0.5 text-foreground">Monthly</h3>
                  <div className="flex items-baseline gap-1 mb-1.5">
                    <span className="text-lg font-[1000] text-foreground">$15</span>
                    <span className="text-[10px] font-bold text-muted-foreground">/mo</span>
                  </div>
                  <p className="text-[10px] text-muted-foreground/80">30 days access</p>
                </div>

                {/* Yearly Plan - Popular */}
                <div
                  className={`p-3 rounded-xl border-2 cursor-pointer transition-all relative overflow-hidden ${selectedPlan === 'yearly'
                    ? 'border-primary bg-primary/5'
                    : 'border-border hover:border-primary/50'
                    }`}
                  onClick={() => setSelectedPlan('yearly')}
                >
                  <Badge className="absolute top-1 right-1 bg-gradient-to-r from-emerald-500 to-teal-500 text-white border-0 text-[9px] px-1.5 py-0">
                    Popular
                  </Badge>
                  <div className="flex items-center justify-between mb-1.5">
                    <div className="w-7 h-7 rounded-full bg-emerald-500/10 flex items-center justify-center">
                      <Sparkles className="h-3.5 w-3.5 text-emerald-500" />
                    </div>
                    {selectedPlan === 'yearly' && (
                      <CheckCircle2 className="h-3.5 w-3.5 text-primary" />
                    )}
                  </div>
                  <h3 className="font-semibold text-xs mb-0.5 text-foreground">Yearly</h3>
                  <div className="flex items-baseline gap-1 mb-1.5">
                    <span className="text-lg font-[1000] text-foreground">$99</span>
                    <span className="text-[10px] font-bold text-muted-foreground">/yr</span>
                  </div>
                  <p className="text-[10px] text-emerald-600 font-semibold">Save 54%</p>
                </div>

                {/* Lifetime Plan */}
                <div
                  className={`p-3 rounded-xl border-2 cursor-pointer transition-all relative overflow-hidden ${selectedPlan === 'lifetime'
                    ? 'border-primary bg-primary/5'
                    : 'border-border hover:border-primary/50'
                    }`}
                  onClick={() => setSelectedPlan('lifetime')}
                >
                  <Badge className="absolute top-1 right-1 bg-gradient-to-r from-amber-500 to-orange-500 text-white border-0 text-[9px] px-1.5 py-0">
                    Best
                  </Badge>
                  <div className="flex items-center justify-between mb-1.5">
                    <div className="w-7 h-7 rounded-full bg-amber-500/10 flex items-center justify-center">
                      <Crown className="h-3.5 w-3.5 text-amber-500" />
                    </div>
                    {selectedPlan === 'lifetime' && (
                      <CheckCircle2 className="h-3.5 w-3.5 text-primary" />
                    )}
                  </div>
                  <h3 className="font-semibold text-xs mb-0.5 text-foreground">Lifetime</h3>
                  <div className="flex items-baseline gap-1 mb-1.5">
                    <span className="text-lg font-[1000] text-foreground">$250</span>
                    <span className="text-[10px] font-bold text-muted-foreground">1x</span>
                  </div>
                  <p className="text-[10px] text-amber-600 font-semibold">Forever</p>
                </div>
              </div>
            )}

            {/* Action Buttons */}
            {!hasPendingRequest && (
              <div className="space-y-2">
                <Button
                  disabled={cryptoLoading}
                  onClick={payWithCrypto}
                  className="w-full btn-gradient rounded-xl py-5 text-base"
                >
                  {cryptoLoading ? (
                    <><Loader2 className="h-4 w-4 mr-2 animate-spin" /> Opening OxaPay…</>
                  ) : (
                    <><Bitcoin className="h-4 w-4 mr-2" /> Pay with Crypto — {selectedPlan === 'monthly' ? '$15' : selectedPlan === 'yearly' ? '$99' : '$250'}</>
                  )}
                </Button>
              </div>
            )}

            {/* Back Link */}
            <div className="text-center mt-3">
              <button
                onClick={() => onOpenChange(false)}
                className="text-sm text-muted-foreground hover:text-foreground"
              >
                ← Continue browsing
              </button>
            </div>
          </div>
        </DialogContent>
      </Dialog>

      <SubscriptionRequestDialog
        open={showRequestDialog}
        onOpenChange={setShowRequestDialog}
        planType={selectedPlan === 'yearly' ? 'lifetime' : selectedPlan}
      />
    </>
  );
}
