import { useEffect, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/hooks/useAuth';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Grid3x3, ExternalLink, Rocket, PlayCircle, Image as ImageIcon, Layers, Instagram, History } from 'lucide-react';
import { Link, useSearchParams, useNavigate } from 'react-router-dom';
import { useCurrency } from '@/hooks/useCurrency';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { igQueryKeys } from '@/lib/instagramCache';

type Row = {
  media_id: string;
  shortcode: string | null;
  permalink: string;
  thumbnail_url: string | null;
  media_type: string | null;
  caption: string | null;
  posted_at: string | null;
  account_id: string | null;
  account_username: string | null;
  total_orders: number;
  active_orders: number;
  completed_orders: number;
  total_spent: number;
};

function TypeIcon({ t }: { t: string | null }) {
  if (t === 'reel' || t === 'video') return <PlayCircle className="w-3.5 h-3.5" />;
  if (t === 'carousel') return <Layers className="w-3.5 h-3.5" />;
  return <ImageIcon className="w-3.5 h-3.5" />;
}

export default function MyPosts() {
  const { user } = useAuth();
  const qc = useQueryClient();
  const { formatPrice } = useCurrency();
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const selectedAccountId = searchParams.get('account');
  const [manualLink, setManualLink] = useState('');
  const [refreshing, setRefreshing] = useState(false);

  const goBoost = (url: string) => navigate(`/engagement-order?link=${encodeURIComponent(url)}`);

  const { data: rows = [], isLoading } = useQuery({
    queryKey: igQueryKeys.postsSummary(user?.id, selectedAccountId),
    queryFn: async () => {
      let mediaQuery = supabase
        .from('instagram_media')
        .select('media_id,shortcode,permalink,thumbnail_url,media_type,caption,posted_at,account_id,instagram_accounts!inner(username)')
        .eq('user_id', user!.id)
        .order('posted_at', { ascending: false, nullsFirst: false });

      if (selectedAccountId) mediaQuery = mediaQuery.eq('account_id', selectedAccountId);

      const { data: media, error: mediaError } = await mediaQuery;
      if (mediaError) throw mediaError;

      const { data: orders, error: ordersError } = await supabase
        .from('engagement_orders')
        .select('link,status,total_price')
        .eq('user_id', user!.id);
      if (ordersError) throw ordersError;

      return (media ?? []).map((m: any) => {
        const matchingOrders = (orders ?? []).filter((o: any) => {
          if (!m.shortcode || !o.link) return false;
          return String(o.link).toLowerCase().includes(String(m.shortcode).toLowerCase());
        });

        return {
          media_id: m.media_id,
          shortcode: m.shortcode,
          permalink: m.permalink,
          thumbnail_url: m.thumbnail_url,
          media_type: m.media_type,
          caption: m.caption,
          posted_at: m.posted_at,
          account_id: m.account_id,
          account_username: m.instagram_accounts?.username ?? null,
          total_orders: matchingOrders.length,
          active_orders: matchingOrders.filter((o: any) => ['pending', 'processing'].includes(o.status)).length,
          completed_orders: matchingOrders.filter((o: any) => o.status === 'completed').length,
          total_spent: matchingOrders.reduce((sum: number, o: any) => sum + Number(o.total_price ?? 0), 0),
        } as Row;
      });
    },
    enabled: !!user?.id,
    // Background scrape lands rows asynchronously — poll until posts appear
    refetchInterval: (query) => {
      const data = query.state.data as Row[] | undefined;
      return !data || data.length === 0 ? 3000 : false;
    },
    refetchIntervalInBackground: false,
  });


  const { data: accounts = [] } = useQuery({
    queryKey: igQueryKeys.accounts(user?.id),
    queryFn: async () => {
      const { data, error } = await supabase.from('instagram_accounts').select('id,username').eq('user_id', user!.id).order('created_at', { ascending: false });
      if (error) throw error;
      return data as any[];
    },
    enabled: !!user?.id,
  });

  // Auto-refresh selected account's media on mount so posts land quickly
  useEffect(() => {
    if (!selectedAccountId) return;
    setRefreshing(true);
    (async () => {
      try {
        await supabase.functions.invoke('instagram-refresh-media', { body: { account_id: selectedAccountId } });
        qc.invalidateQueries({ queryKey: igQueryKeys.postsSummary() });
      } catch { /* silent */ }
      finally { setRefreshing(false); }
    })();
  }, [selectedAccountId, qc]);

  // realtime: any engagement order change or new IG media → refetch
  useEffect(() => {
    if (!user?.id) return;
    const ch = supabase
      .channel(`eo-mypost-${user.id}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'engagement_orders', filter: `user_id=eq.${user.id}` },
        () => qc.invalidateQueries({ queryKey: igQueryKeys.postsSummary() }))
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'instagram_media', filter: `user_id=eq.${user.id}` },
        () => qc.invalidateQueries({ queryKey: igQueryKeys.postsSummary() }))
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [user?.id, qc]);


  const selectedAccount = selectedAccountId ? accounts.find((a) => a.id === selectedAccountId) : null;


  return (
    <DashboardLayout>
      <div className="max-w-6xl mx-auto space-y-5">
        {/* Minimal editorial header */}
        <div className="flex items-end justify-between gap-4 pt-2 border-b border-white/10 pb-5">
          <div className="min-w-0">
            <div className="flex items-center gap-2 text-[11px] uppercase tracking-[0.22em] text-white/40 mb-2">
              <span className="h-1.5 w-1.5 rounded-full bg-violet-400" />
              {selectedAccount ? 'Account feed' : 'Command center'}
            </div>
            <h1 className="text-2xl md:text-3xl font-semibold !text-white tracking-tight truncate">
              {selectedAccount ? (
                <><span className="text-white/40">@</span>{selectedAccount.username}<span className="text-white/40 font-normal"> — posts</span></>
              ) : 'Post Command Center'}
            </h1>
          </div>
          <Link to="/instagram" className="shrink-0 text-sm text-white/60 hover:text-white underline underline-offset-4 decoration-white/20 hover:decoration-white/60 transition-colors">
            Accounts
          </Link>
        </div>

        {accounts.length > 1 && (
          <div className="flex items-center gap-5 overflow-x-auto pb-1 -mt-1">
            {accounts.map((a) => {
              const active = selectedAccountId === a.id;
              return (
                <button
                  key={a.id}
                  onClick={() => navigate(`/my-posts?account=${encodeURIComponent(a.id)}`)}
                  className={`shrink-0 text-sm transition-colors relative pb-1 ${active ? 'text-white' : 'text-white/40 hover:text-white/70'}`}
                >
                  @{a.username}
                  {active && <span className="absolute left-0 right-0 -bottom-0.5 h-px bg-violet-400" />}
                </button>
              );
            })}
          </div>
        )}

        {/* Boost link input */}
        <div className="relative group">
          <div className="absolute -inset-0.5 bg-gradient-to-r from-violet-600/20 to-fuchsia-600/20 rounded-2xl blur opacity-60 group-focus-within:opacity-100 transition duration-700 pointer-events-none"></div>
          <div className="relative flex flex-col sm:flex-row items-stretch sm:items-center gap-2 p-2 rounded-2xl bg-[#ffffff] border border-white/10 shadow-2xl">
            <Input
              placeholder={selectedAccount ? `Paste a link from @${selectedAccount.username}…` : 'Paste any Instagram reel/post link…'}
              value={manualLink}
              onChange={(e) => setManualLink(e.target.value)}
              className="flex-1 bg-transparent border-none focus-visible:ring-0 focus-visible:ring-offset-0 text-white/90 placeholder:text-white/35 px-4 text-sm h-11"
            />
            <Button
              onClick={() => { if (/instagram\.com\//i.test(manualLink)) goBoost(manualLink.trim()); }}
              disabled={!/instagram\.com\//i.test(manualLink)}
              className="h-11 px-6 rounded-xl bg-gradient-to-br from-violet-500 to-violet-700 hover:from-violet-500 hover:to-violet-600 text-white font-semibold text-sm hover:shadow-[0_0_20px_rgba(139,92,246,0.35)] transition-all"
            >
              <Rocket className="w-4 h-4 mr-1.5" /> Boost Link
            </Button>
          </div>
        </div>



        {(isLoading || (refreshing && rows.length === 0)) && (
          <div className="space-y-3">
            {refreshing && rows.length === 0 && (
              <p className="text-center text-[12px] text-white/60">Fetching latest posts from Instagram…</p>
            )}
            <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-3">
              {Array.from({ length: 8 }).map((_, i) => (
                <div key={i} className="aspect-square rounded-2xl bg-white/5 animate-pulse" />
              ))}
            </div>
          </div>
        )}

        {!isLoading && !refreshing && rows.length === 0 && (
          <div className="text-center py-14 rounded-2xl border border-dashed border-white/10 space-y-3">
            <Instagram className="w-10 h-10 text-white/65 mx-auto" />
            <p className="text-white/80 text-sm">No posts found for this account yet.</p>
            <Link to="/instagram" className="inline-flex items-center gap-2 px-4 h-10 rounded-xl bg-gradient-to-b from-purple-500 to-fuchsia-600 text-white text-sm font-semibold">
              Back to Instagram Accounts
            </Link>
          </div>
        )}

        <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-3">
          {rows.map((r) => (
            <div key={r.media_id} className="rounded-2xl overflow-hidden bg-[#ffffff]/80 border border-white/10 hover:border-purple-400/30 transition-colors group">
              <div className="relative aspect-square bg-black">
                {r.thumbnail_url ? (
                  <img src={`https://lvrbhgulxqdsamhdjzkw.supabase.co/functions/v1/ig-image-proxy?url=${encodeURIComponent(r.thumbnail_url)}`} alt="" loading="lazy" referrerPolicy="no-referrer" className="w-full h-full object-cover" onError={(e) => { (e.target as HTMLImageElement).style.opacity = '0.2'; }} />
                ) : (
                  <div className="w-full h-full flex items-center justify-center text-white/80"><ImageIcon className="w-10 h-10" /></div>
                )}
                <div className="absolute top-2 left-2 flex items-center gap-1 px-2 h-6 rounded-full bg-black/70 backdrop-blur text-[10px] font-semibold text-white/90 uppercase">
                  <TypeIcon t={r.media_type} /> {r.media_type ?? 'post'}
                </div>
                <a href={r.permalink} target="_blank" rel="noopener noreferrer"
                  className="absolute top-2 right-2 w-7 h-7 rounded-full bg-black/70 backdrop-blur flex items-center justify-center text-white/80 hover:text-white opacity-0 group-hover:opacity-100 transition-opacity">
                  <ExternalLink className="w-3.5 h-3.5" />
                </a>
                <div className="absolute bottom-0 left-0 right-0 flex gap-1 p-2">
                  {r.active_orders > 0 && (
                    <span className="px-2 h-6 rounded-full bg-amber-500/90 text-black text-[10px] font-bold flex items-center">
                      Active {r.active_orders}
                    </span>
                  )}
                  {r.completed_orders > 0 && (
                    <span className="px-2 h-6 rounded-full bg-emerald-500/90 text-black text-[10px] font-bold flex items-center">
                      ✓ {r.completed_orders}
                    </span>
                  )}
                </div>
              </div>
              <div className="p-3 space-y-2">
                <p className="text-[11px] text-white/80 line-clamp-2 min-h-[2.4em]">{r.caption || '—'}</p>
                <div className="flex items-center justify-between text-[10px] text-white/75">
                  <span>@{r.account_username}</span>
                  {r.total_spent > 0 && <span className="text-emerald-300/80 font-semibold">{formatPrice(Number(r.total_spent))}</span>}
                </div>
                <button
                  onClick={() => goBoost(r.permalink)}
                  className="w-full h-9 rounded-lg text-[12px] font-semibold bg-gradient-to-b from-purple-500 to-fuchsia-600 text-white shadow-md shadow-purple-500/20 hover:shadow-purple-500/40 flex items-center justify-center gap-1.5"
                >
                  <Rocket className="w-3.5 h-3.5" /> Boost
                </button>
                {(r.active_orders > 0 || r.completed_orders > 0 || Number(r.total_spent) > 0) && (
                  <button
                    onClick={() => navigate(`/engagement-orders?q=${encodeURIComponent(r.permalink)}`)}
                    className="w-full h-8 rounded-lg text-[11px] font-medium bg-white/5 hover:bg-white/10 border border-white/10 text-white/80 hover:text-white flex items-center justify-center gap-1.5 transition"
                  >
                    <History className="w-3.5 h-3.5" /> Order history
                  </button>
                )}

              </div>
            </div>
          ))}
        </div>
      </div>
    </DashboardLayout>

  );
}
