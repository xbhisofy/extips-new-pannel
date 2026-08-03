import { igImageUrl } from "@/lib/igImage";
import { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/hooks/useAuth';
import { useSubscription } from '@/hooks/useSubscription';
import { SubscriptionCheckDialog } from '@/components/subscription/SubscriptionCheckDialog';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Instagram, Loader2, Plus, Trash2, CheckCircle2, ShieldAlert, Lock } from 'lucide-react';
import { toast } from 'sonner';
import { Link } from 'react-router-dom';
import { igQueryKeys } from '@/lib/instagramCache';

export default function InstagramPage() {
  const { user } = useAuth();
  const { subscription, hasActiveSubscription, isLoading: subLoading } = useSubscription();
  const [showSubDialog, setShowSubDialog] = useState(false);
  const qc = useQueryClient();
  const [username, setUsername] = useState('');

  const { data: accounts = [], isLoading } = useQuery({
    queryKey: igQueryKeys.accounts(user?.id),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('instagram_accounts').select('*')
        .eq('user_id', user!.id).order('created_at', { ascending: false });
      if (error) throw error;
      return data;
    },
    enabled: !!user?.id,
    // While a freshly linked row is still being scraped, poll so the profile
    // and post counts appear without a manual reload.
    refetchInterval: (q) =>
      (q.state.data as any[] | undefined)?.some((a) => a.status === 'pending_refresh') ? 4000 : false,
  });


  // Persistent 30-day link usage from audit log (survives account deletion).
  const { data: linkEvents = [] } = useQuery({
    queryKey: igQueryKeys.linkEvents(user?.id),
    queryFn: async () => {
      const since = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
      const { data, error } = await supabase
        .from('instagram_link_events')
        .select('username, created_at')
        .eq('user_id', user!.id)
        .eq('event_type', 'link')
        .gte('created_at', since)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data;
    },
    enabled: !!user?.id,
  });

  const linkMut = useMutation({
    mutationFn: async (u: string) => {
      const { data, error } = await supabase.functions.invoke('instagram-link-account', { body: { username: u } });
      if (error) {
        // Parse the actual server error body (functions.invoke returns non-2xx as generic error)
        let msg = error.message;
        try {
          const ctx: any = (error as any).context;
          if (ctx?.json) { const j = await ctx.json(); if (j?.error) msg = j.error; }
          else if (ctx?.text) { const t = await ctx.text(); const j = JSON.parse(t); if (j?.error) msg = j.error; }
        } catch { /* ignore */ }
        throw new Error(msg);
      }
      if (data?.error) throw new Error(data.error);
      return data;
    },
    onSuccess: (d) => {
      toast.success(`Linked @${d.account.username} · ${d.imported} posts imported`);
      setUsername('');
      qc.invalidateQueries({ queryKey: igQueryKeys.accounts() });
      qc.invalidateQueries({ queryKey: igQueryKeys.linkEvents() });
      qc.invalidateQueries({ queryKey: igQueryKeys.postsSummary() });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const removeMut = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('instagram_accounts').delete().eq('id', id);
      if (error) throw error;
    },
    onSuccess: () => {
      toast.success('Account removed');
      qc.invalidateQueries({ queryKey: igQueryKeys.accounts() });
      qc.invalidateQueries({ queryKey: igQueryKeys.postsSummary() });
    },
  });

  return (
    <DashboardLayout>
      <div className="max-w-4xl mx-auto space-y-6">
        <div className="rounded-3xl p-6 bg-gradient-to-br from-purple-600/15 via-fuchsia-500/10 to-transparent border border-purple-400/20">
          <div className="flex items-center gap-3 mb-2">
            <div className="w-11 h-11 rounded-2xl flex items-center justify-center bg-gradient-to-br from-fuchsia-500 to-purple-600 shadow-lg">
              <Instagram className="w-6 h-6 text-white" />
            </div>
            <div>
              <h1 className="text-2xl font-bold !text-white">Instagram Accounts</h1>
              <p className="text-sm text-white/85">Link your IG account to import posts and boost engagement.</p>
            </div>
          </div>
        </div>

        {/* Subscription status banner */}
        {!subLoading && (() => {
          const plan = subscription?.plan_type ?? 'none';
          const expiresAt = subscription?.expires_at ? new Date(subscription.expires_at) : null;
          const expiresStr = expiresAt ? expiresAt.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' }) : null;
          const daysLeft = expiresAt ? Math.ceil((expiresAt.getTime() - Date.now()) / 86400000) : null;
          const isLifetime = plan === 'lifetime' && hasActiveSubscription;
          if (hasActiveSubscription) {
            return (
              <div className="rounded-2xl p-4 bg-gradient-to-r from-emerald-500/10 to-emerald-400/5 border border-emerald-400/30 flex items-center gap-3">
                <div className="w-10 h-10 rounded-xl bg-emerald-500/20 border border-emerald-400/30 flex items-center justify-center shrink-0">
                  <CheckCircle2 className="w-5 h-5 text-emerald-300" />
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className="text-sm font-semibold text-emerald-200">Subscription Active</span>
                    <span className="text-[10px] uppercase tracking-wider px-2 py-0.5 rounded-full bg-emerald-500/20 text-emerald-200 border border-emerald-400/30">
                      {plan}
                    </span>
                  </div>
                  <p className="text-xs text-white/85 mt-0.5">
                    {isLifetime
                      ? 'Lifetime access — never expires.'
                      : expiresStr
                        ? `Expires on ${expiresStr}${daysLeft !== null && daysLeft >= 0 ? ` · ${daysLeft} day${daysLeft === 1 ? '' : 's'} left` : ''}`
                        : 'Active plan'}
                  </p>
                </div>
              </div>
            );
          }
          return (
            <div className="rounded-2xl p-4 bg-gradient-to-r from-rose-500/10 to-amber-500/5 border border-rose-400/30 flex items-center gap-3">
              <div className="w-10 h-10 rounded-xl bg-rose-500/20 border border-rose-400/30 flex items-center justify-center shrink-0">
                <Lock className="w-5 h-5 text-rose-300" />
              </div>
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2 flex-wrap">
                  <span className="text-sm font-semibold text-rose-200">Subscription Inactive</span>
                  {subscription?.status === 'expired' && expiresStr && (
                    <span className="text-[10px] uppercase tracking-wider px-2 py-0.5 rounded-full bg-rose-500/20 text-rose-200 border border-rose-400/30">
                      Expired {expiresStr}
                    </span>
                  )}
                </div>
                <p className="text-xs text-white/85 mt-0.5">
                  Linking Instagram accounts requires an active plan.
                </p>
              </div>
              <button
                onClick={() => setShowSubDialog(true)}
                className="shrink-0 h-9 px-3 rounded-lg text-xs font-semibold bg-gradient-to-b from-purple-500 to-fuchsia-600 text-white shadow-md hover:shadow-purple-500/40"
              >
                Activate
              </button>
            </div>
          );
        })()}

        <div className="rounded-2xl p-5 bg-[#ffffff]/80 border border-white/10">
          <label className="block text-xs font-semibold uppercase tracking-wider text-white/80 mb-2">Add Instagram Username</label>
          <div className="flex gap-2">
            <div className="flex-1 relative">
              <span className="absolute left-3 top-1/2 -translate-y-1/2 text-white/75">@</span>
              <input
                value={username}
                onChange={(e) => setUsername(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter' && username) { if (!hasActiveSubscription) { setShowSubDialog(true); } else { linkMut.mutate(username); } } }}
                placeholder="your_username"
                className="w-full h-11 pl-8 pr-3 rounded-xl bg-black/40 border border-white/10 text-white placeholder:text-white/65 focus:outline-none focus:border-purple-400/40"
              />
            </div>
            <button
              disabled={!username || linkMut.isPending || subLoading}
              onClick={() => {
                if (!hasActiveSubscription) { setShowSubDialog(true); return; }
                linkMut.mutate(username);
              }}
              className="h-11 px-5 rounded-xl font-semibold bg-gradient-to-b from-purple-500 to-fuchsia-600 text-white shadow-lg shadow-purple-500/30 hover:shadow-purple-500/50 transition-all disabled:opacity-50 flex items-center gap-2"
            >
              {linkMut.isPending ? <Loader2 className="w-4 h-4 animate-spin" /> : (hasActiveSubscription ? <Plus className="w-4 h-4" /> : <Lock className="w-4 h-4" />)}
              Link
            </button>
          </div>
          <p className="mt-2 text-[11px] text-white/75 flex items-center gap-1.5">
            <ShieldAlert className="w-3 h-3" /> Read-only. We only fetch public profile info & posts.
          </p>

          {hasActiveSubscription && (() => {
            const cutoff = Date.now() - 30 * 24 * 60 * 60 * 1000;
            const recent = (linkEvents as any[]).filter(e => new Date(e.created_at).getTime() >= cutoff);
            const used = recent.length;
            const remaining = Math.max(0, 5 - used);
            const blocked = remaining === 0;
            const oldest = recent.reduce<Date | null>((min, a) => {
              const d = new Date(a.created_at);
              return !min || d < min ? d : min;
            }, null);
            const resetAt = oldest ? new Date(oldest.getTime() + 30 * 24 * 60 * 60 * 1000) : null;
            const resetStr = resetAt ? resetAt.toLocaleDateString('en-IN', { day: '2-digit', month: 'short' }) : null;
            return (
              <div className={`mt-3 rounded-xl px-3 py-2 text-[12px] flex items-center gap-2 border ${
                blocked
                  ? 'bg-rose-500/10 border-rose-400/30 text-rose-200'
                  : remaining <= 1
                    ? 'bg-amber-500/10 border-amber-400/30 text-amber-200'
                    : 'bg-emerald-500/10 border-emerald-400/30 text-emerald-200'
              }`}>
                {blocked ? <Lock className="w-3.5 h-3.5 shrink-0" /> : <CheckCircle2 className="w-3.5 h-3.5 shrink-0" />}
                <span className="font-semibold">{used}/5 links used</span>
                <span className="opacity-80">·</span>
                <span>
                  {blocked
                    ? `Monthly limit reached. Slot frees on ${resetStr}, or remove an existing account.`
                    : `${remaining} more account${remaining === 1 ? '' : 's'} can be linked in this 30-day window${resetStr ? ` · next reset ${resetStr}` : ''}.`}
                </span>
              </div>
            );
          })()}

        </div>


        <div className="space-y-3">
          {isLoading && <div className="text-center text-white/80 py-8">Loading...</div>}
          {!isLoading && accounts.length === 0 && (
            <div className="text-center py-10 rounded-2xl border border-dashed border-white/10 text-white/75">
              No Instagram accounts linked yet.
            </div>
          )}
          {accounts.map((a: any) => (
            <div key={a.id} className="rounded-2xl p-4 bg-[#ffffff]/80 border border-white/10 flex items-center gap-4">
              <div className="relative w-14 h-14 shrink-0">
                <div className="absolute inset-0 rounded-full bg-gradient-to-br from-fuchsia-500 to-purple-600 flex items-center justify-center text-white font-bold text-lg ring-2 ring-purple-400/30">
                  {a.username[0]?.toUpperCase()}
                </div>
                {a.avatar_url && (
                  <img
                    src={igImageUrl(a.avatar_url)}
                    alt={a.username}
                    referrerPolicy="no-referrer"
                    loading="lazy"
                    className="absolute inset-0 w-14 h-14 rounded-full object-cover ring-2 ring-purple-400/30 transition-opacity duration-300 opacity-0"
                    onLoad={(e) => { (e.target as HTMLImageElement).style.opacity = '1'; }}
                    onError={(e) => { (e.target as HTMLImageElement).style.display = 'none'; }}
                  />
                )}
              </div>
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-1.5">
                  <span className="font-semibold !text-white truncate">@{a.username}</span>
                  {a.is_verified && <CheckCircle2 className="w-4 h-4 text-sky-400 shrink-0" />}
                </div>
                {a.full_name && <p className="text-[13px] text-white/85 truncate">{a.full_name}</p>}
                <p className="text-[11px] text-white/75 mt-0.5">
                  {a.followers?.toLocaleString('en-IN') ?? 0} followers · {a.posts_count ?? 0} posts
                </p>
              </div>
              <div className="flex items-center gap-2 shrink-0">
                <Link to={`/my-posts?account=${encodeURIComponent(a.id)}`} className="px-3 h-9 rounded-lg text-[12px] font-semibold bg-white/5 hover:bg-white/10 border border-white/10 text-white/80 flex items-center">
                  View Posts
                </Link>
                <button
                  onClick={() => confirm(`Remove @${a.username}?`) && removeMut.mutate(a.id)}
                  className="w-9 h-9 rounded-lg bg-red-500/10 hover:bg-red-500/20 border border-red-400/20 text-red-300 flex items-center justify-center"
                  title="Remove"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            </div>
          ))}
        </div>
      </div>
      <SubscriptionCheckDialog open={showSubDialog} onOpenChange={setShowSubDialog} />
    </DashboardLayout>
  );
}
