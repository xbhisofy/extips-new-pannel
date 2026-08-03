import React from 'react';
import { Link } from 'react-router-dom';
import {
  ArrowRight, Sparkles, Zap, Shield, BarChart3, Wallet as WalletIcon,
  Shuffle, Activity, Check, Instagram, Youtube, MessageCircle, Globe
} from 'lucide-react';
import { PageMeta } from '@/components/seo/PageMeta';
import logo from '@/assets/logo.jpg';
import { useAuth } from '@/hooks/useAuth';

/**
 * Extips Panel Pro — Software-style landing (Violet Aurora).
 * Dark canvas, fine grid, violet aurora glows, display headline with serif italic accent.
 */

const Index = () => {
  const { user } = useAuth();
  const monthlyPayHref = user ? '/wallet?subscribe=monthly' : `/auth?next=${encodeURIComponent('/wallet?subscribe=monthly')}`;
  const yearlyPayHref = user ? '/wallet?subscribe=yearly' : `/auth?next=${encodeURIComponent('/wallet?subscribe=yearly')}`;
  const lifetimePayHref = user ? '/wallet?subscribe=lifetime' : `/auth?next=${encodeURIComponent('/wallet?subscribe=lifetime')}`;


  return (
    <div className="min-h-screen w-full bg-white text-foreground overflow-x-hidden antialiased">
      <PageMeta
        title="Extips Panel Pro — The Growth Engine for Social Magic"
        description="Precision-engineered organic engagement for Instagram, TikTok and YouTube. Multi-provider failover, wallet, live dashboard."
        canonicalPath="/"
        breadcrumbs={[{ name: 'Home', path: '/' }]}
      />

      {/* Global ambient layers */}
      <div aria-hidden className="pointer-events-none fixed inset-0 -z-10">
        {/* Grid */}
        <div
          className="absolute inset-0 opacity-[0.12]"
          style={{
            backgroundImage:
              'linear-gradient(#475569 1px, transparent 1px), linear-gradient(90deg, #475569 1px, transparent 1px)',
            backgroundSize: '44px 44px',
            maskImage:
              'radial-gradient(ellipse at center, black 40%, transparent 80%)',
            WebkitMaskImage:
              'radial-gradient(ellipse at center, black 40%, transparent 80%)',
          }}
        />
        {/* Aurora */}
        <div className="absolute top-[-15%] left-1/2 -translate-x-1/2 w-[900px] h-[480px] bg-purple-600/30 blur-[140px] rounded-full" />
        <div className="absolute top-[20%] right-[-10%] w-[480px] h-[480px] bg-fuchsia-600/15 blur-[120px] rounded-full" />
        <div className="absolute bottom-[-20%] left-[-10%] w-[520px] h-[520px] bg-indigo-600/15 blur-[140px] rounded-full" />
      </div>

      {/* Nav */}
      <header className="sticky top-0 z-40 backdrop-blur-md bg-[#f5f9ff]/60 border-b border-white/5">
        <div className="max-w-6xl mx-auto px-5 sm:px-8 h-16 flex items-center justify-between">
          <Link to="/" className="flex items-center gap-2.5">
            <img src={logo} alt="Extips Panel Pro" width={32} height={32} fetchPriority="high" decoding="async" className="h-8 w-8 rounded-md object-cover ring-1 ring-white/10" />
            <span className="text-[15px] font-semibold tracking-tight">Extips Panel Pro</span>
            <span className="hidden sm:inline text-[10px] uppercase tracking-[0.18em] text-white/75 ml-2 px-1.5 py-0.5 rounded border border-white/10">v2</span>
          </Link>

          <nav className="hidden md:flex items-center gap-8 text-sm text-white/85">
            <a href="#features" className="hover:text-white transition-colors">Features</a>
            <a href="#platforms" className="hover:text-white transition-colors">Platforms</a>
            <a href="#pricing" className="hover:text-white transition-colors">Pricing</a>
            <Link to="/support" className="hover:text-white transition-colors">Support</Link>
          </nav>

          <div className="flex items-center gap-2.5">
            <Link
              to="/auth"
              className="hidden sm:inline-flex text-sm text-white/70 hover:text-white px-3 py-2 rounded-lg transition-colors"
            >
              Sign in
            </Link>
            <Link
              to="/auth"
              className="inline-flex items-center gap-1.5 text-sm font-semibold px-4 py-2 rounded-lg bg-white text-black hover:bg-purple-50 transition-all shadow-[0_0_24px_rgba(255,255,255,0.12)] active:scale-[0.98]"
            >
              Get started <ArrowRight className="h-3.5 w-3.5" />
            </Link>
          </div>
        </div>
      </header>
      <main>
      {/* Hero */}
      <section className="relative">
        <div className="max-w-5xl mx-auto px-5 sm:px-8 pt-20 sm:pt-28 pb-20 sm:pb-28 text-center">
          {/* Badge */}
          <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full border border-white/10 bg-white/[0.04] backdrop-blur-sm mb-8">
            <span className="relative flex h-2 w-2">
              <span className="absolute inline-flex h-full w-full rounded-full bg-purple-400 opacity-75 animate-ping" />
              <span className="relative inline-flex rounded-full h-2 w-2 bg-purple-500" />
            </span>
            <span className="text-[11px] font-medium tracking-[0.18em] uppercase text-purple-200/70">
              Extips Panel Pro Software v2.0
            </span>
          </div>

          {/* Headline */}
          <h1
            className="!text-white text-5xl sm:text-7xl lg:text-[88px] font-extrabold tracking-tight leading-[1.02] mb-6"
            style={{ fontFamily: "'Inter', system-ui, sans-serif" }}
          >
            The Growth Engine
            <br />
            for Social{' '}
            <span
              className="italic font-bold text-purple-300"
              style={{ fontFamily: "'Playfair Display', Georgia, serif" }}
            >
              Magic
            </span>
          </h1>

          {/* Sub */}
          <p className="text-base sm:text-xl text-slate-200 max-w-2xl mx-auto mb-10 leading-relaxed">
            Master Instagram, TikTok, and YouTube organic engagement through a
            precision-engineered platform. No bots — just high-performance
            software with multi-provider failover, wallet, and a live dashboard.
          </p>

          {/* CTA */}
          <div className="flex flex-col sm:flex-row items-center justify-center gap-3 sm:gap-4">
            <Link
              to="/auth"
              className="w-full sm:w-auto inline-flex items-center justify-center gap-2 px-7 py-3.5 bg-white text-black font-semibold rounded-xl hover:bg-purple-50 transition-all shadow-[0_0_24px_rgba(255,255,255,0.15)] active:scale-[0.98]"
            >
              Launch Dashboard <ArrowRight className="h-4 w-4" />
            </Link>
            <a
              href="#pricing"
              className="w-full sm:w-auto inline-flex items-center justify-center px-7 py-3.5 bg-white/5 border border-white/10 text-white font-semibold rounded-xl hover:bg-white/10 transition-all backdrop-blur-md"
            >
              View pricing
            </a>
          </div>

          {/* Platforms strip */}
          <div className="mt-20 pt-8 border-t border-white/5">
            <p className="text-[10px] tracking-[0.24em] uppercase text-white/65 mb-5">
              Built for the platforms that matter
            </p>
            <div className="flex flex-wrap items-center justify-center gap-x-10 gap-y-4 text-white/80">
              {[
                { Icon: Instagram, label: 'INSTAGRAM' },
                { Icon: Sparkles, label: 'TIKTOK' },
                { Icon: Youtube, label: 'YOUTUBE' },
                { Icon: MessageCircle, label: 'TELEGRAM' },
                { Icon: Globe, label: 'FACEBOOK' },
              ].map(({ Icon, label }) => (
                <div key={label} className="flex items-center gap-2 hover:text-white/80 transition-colors">
                  <Icon className="h-4 w-4" />
                  <span className="text-xs font-semibold tracking-[0.18em]">{label}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </section>

      {/* Features */}
      <section id="features" className="relative py-24 sm:py-32 border-t border-white/5">
        <div className="max-w-6xl mx-auto px-5 sm:px-8">
          <div className="max-w-2xl mb-14">
            <p className="text-[11px] tracking-[0.22em] uppercase text-purple-300/70 mb-4">
              The Software
            </p>
            <h2 className="!text-white text-3xl sm:text-5xl font-bold tracking-tight leading-[1.1]">
              Engineered like infrastructure,
              <br />
              <span
                className="italic text-purple-300"
                style={{ fontFamily: "'Playfair Display', Georgia, serif" }}
              >
                used like a product.
              </span>
            </h2>
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4 sm:gap-5">
            {[
              {
                Icon: Activity,
                title: 'Organic Drip-Feed',
                body: 'Time-spread delivery with natural variance — engagement that looks human because the schedule is.',
              },
              {
                Icon: Shuffle,
                title: 'Multi-Provider Failover',
                body: 'Auto-rotation across providers with live balance monitoring. Zero balance? Backup provider takes over.',
              },
              {
                Icon: WalletIcon,
                title: 'Wallet & UPI Deposits',
                body: 'Fully automatic ZapUPI top-ups. No screenshots, no approvals. Credited the second payment clears.',
              },
              {
                Icon: BarChart3,
                title: 'Live Dashboard',
                body: 'Real-time runs, status, charts. Watch every dispatch tick across providers as it happens.',
              },
              {
                Icon: Shield,
                title: 'Subscription Gated',
                body: 'Locked behind monthly or lifetime plans, so the system stays clean and the queue stays fast.',
              },
              {
                Icon: Zap,
                title: 'Bundles & Mass Order',
                body: 'One click ships engagement combos across multiple posts — built for creators who scale fast.',
              },
            ].map(({ Icon, title, body }) => (
              <div
                key={title}
                className="group relative rounded-2xl border border-white/10 bg-white/[0.03] p-6 hover:bg-white/[0.06] hover:border-white/20 transition-all backdrop-blur-sm"
              >
                <div className="h-10 w-10 rounded-lg bg-purple-500/10 border border-purple-400/20 flex items-center justify-center mb-5">
                  <Icon className="h-5 w-5 text-purple-300" />
                </div>
                <h3 className="text-base font-semibold mb-2">{title}</h3>
                <p className="text-sm text-slate-200 leading-relaxed">{body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Platforms */}
      <section id="platforms" className="relative py-24 border-t border-white/5">
        <div className="max-w-6xl mx-auto px-5 sm:px-8 grid lg:grid-cols-2 gap-12 items-center">
          <div>
            <p className="text-[11px] tracking-[0.22em] uppercase text-purple-300/70 mb-4">
              Cross-platform
            </p>
            <h2 className="!text-white text-3xl sm:text-5xl font-bold tracking-tight leading-[1.1] mb-5">
              One control room for{' '}
              <span
                className="italic text-purple-300"
                style={{ fontFamily: "'Playfair Display', Georgia, serif" }}
              >
                every channel.
              </span>
            </h2>
            <p className="text-slate-200 leading-relaxed mb-8 max-w-lg">
              Plug in a URL, pick a bundle, hit launch. Extips Panel Pro handles the
              routing, the dispatch, and the retries — so you don't have to
              babysit any of it.
            </p>
            <ul className="space-y-3">
              {[
                'Instagram followers, likes, views & reels',
                'TikTok views, hearts & followers',
                'YouTube views, subs & engagement',
                'Telegram, Facebook, X — all routed',
              ].map((t) => (
                <li key={t} className="flex items-center gap-3 text-sm text-slate-100">
                  <span className="h-5 w-5 rounded-full bg-purple-500/15 border border-purple-400/30 flex items-center justify-center shrink-0">
                    <Check className="h-3 w-3 text-purple-300" />
                  </span>
                  {t}
                </li>
              ))}
            </ul>
          </div>

          <div className="relative">
            <div className="absolute -inset-6 bg-purple-600/20 blur-[80px] rounded-full" />
            <div className="relative rounded-2xl border border-white/10 bg-gradient-to-br from-white/[0.06] to-white/[0.02] p-6 backdrop-blur-md shadow-[0_30px_80px_-20px_rgba(124,58,237,0.4)]">
              <div className="flex items-center gap-1.5 mb-5">
                <span className="h-2.5 w-2.5 rounded-full bg-white/20" />
                <span className="h-2.5 w-2.5 rounded-full bg-white/20" />
                <span className="h-2.5 w-2.5 rounded-full bg-white/20" />
                <span className="ml-auto text-[10px] uppercase tracking-[0.18em] text-white/75">extipspanel.live</span>
              </div>
              <div className="space-y-3">
                {[
                  { p: 'Instagram', t: 'Reel views', q: '12,500', s: 'Running' },
                  { p: 'TikTok', t: 'Hearts', q: '4,200', s: 'Queued' },
                  { p: 'YouTube', t: 'Subscribers', q: '850', s: 'Complete' },
                  { p: 'Instagram', t: 'Followers', q: '2,000', s: 'Running' },
                ].map((r, i) => (
                  <div key={i} className="flex items-center justify-between rounded-lg border border-white/5 bg-white/[0.03] px-3.5 py-3">
                    <div>
                      <div className="text-[10px] uppercase tracking-widest text-white/75 mb-0.5">{r.p}</div>
                      <div className="text-sm font-medium">{r.t}</div>
                    </div>
                    <div className="text-right">
                      <div className="text-sm font-semibold">{r.q}</div>
                      <div className={`text-[10px] uppercase tracking-widest ${r.s === 'Complete' ? 'text-emerald-300/80' : r.s === 'Queued' ? 'text-amber-300/80' : 'text-purple-300/80'}`}>
                        {r.s}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Pricing */}
      <section id="pricing" className="relative py-24 sm:py-32 border-t border-white/5">
        <div className="max-w-5xl mx-auto px-5 sm:px-8">
          <div className="text-center mb-14">
            <p className="text-[11px] tracking-[0.22em] uppercase text-purple-300/70 mb-4">
              Pricing
            </p>
            <h2 className="!text-white text-3xl sm:text-5xl font-bold tracking-tight leading-[1.1]">
              Three plans.{' '}
              <span
                className="italic text-purple-300"
                style={{ fontFamily: "'Playfair Display', Georgia, serif" }}
              >
                All unlock everything.
              </span>
            </h2>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-5">
            {/* Monthly */}
            <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-7 backdrop-blur-sm">
              <div className="flex items-baseline justify-between mb-1">
                <h3 className="text-lg font-semibold">Monthly</h3>
                <span className="text-[10px] uppercase tracking-[0.18em] text-white/75">Most flexible</span>
              </div>
              <div className="mt-3 mb-5">
                <span className="text-5xl font-bold tracking-tight">$15</span>
                <span className="text-white/75 ml-2 text-sm">/ month</span>
              </div>
              <p className="text-sm text-slate-200 mb-6">Full access. Cancel anytime.</p>
              <a
                href={monthlyPayHref}
                className="inline-flex w-full items-center justify-center px-5 py-3 rounded-xl bg-white/5 border border-white/10 hover:bg-white/10 text-white font-semibold transition-all"
              >
                {user ? 'Pay $15 & activate' : 'Start monthly'}
              </a>


              <ul className="mt-6 space-y-2.5 text-sm text-slate-100">
                {['Unlimited orders', 'All platforms', 'Multi-provider failover', 'Live dashboard'].map((t) => (
                  <li key={t} className="flex items-center gap-2.5">
                    <Check className="h-4 w-4 text-purple-300" /> {t}
                  </li>
                ))}
              </ul>
            </div>

            {/* Yearly */}
            <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-7 backdrop-blur-sm">
              <div className="flex items-baseline justify-between mb-1">
                <h3 className="text-lg font-semibold">Yearly</h3>
                <span className="text-[10px] uppercase tracking-[0.18em] text-white/75">Save more</span>
              </div>
              <div className="mt-3 mb-5">
                <span className="text-5xl font-bold tracking-tight">$99</span>
                <span className="text-white/75 ml-2 text-sm">/ year</span>
              </div>
              <p className="text-sm text-slate-200 mb-6">12 months of full access.</p>
              <Link
                to={yearlyPayHref}
                className="inline-flex w-full items-center justify-center px-5 py-3 rounded-xl bg-white/5 border border-white/10 hover:bg-white/10 text-white font-semibold transition-all"
              >
                Start yearly
              </Link>
              <ul className="mt-6 space-y-2.5 text-sm text-slate-100">
                {['Everything in Monthly', 'Best monthly value', 'Priority support', 'Live dashboard'].map((t) => (
                  <li key={t} className="flex items-center gap-2.5">
                    <Check className="h-4 w-4 text-purple-300" /> {t}
                  </li>
                ))}
              </ul>
            </div>

            {/* Lifetime */}
            <div className="relative rounded-2xl border border-purple-400/40 bg-gradient-to-b from-purple-600/10 to-white/[0.02] p-7 backdrop-blur-sm overflow-hidden">
              <div className="absolute -top-20 -right-20 w-64 h-64 bg-purple-500/20 blur-[80px] rounded-full pointer-events-none" />
              <div className="flex items-baseline justify-between mb-1">
                <h3 className="text-lg font-semibold">Lifetime</h3>
                <span className="text-[10px] uppercase tracking-[0.18em] text-purple-200/80 px-2 py-0.5 rounded-full bg-purple-500/20 border border-purple-400/30">
                  Best value
                </span>
              </div>
              <div className="mt-3 mb-5">
                <span className="text-5xl font-bold tracking-tight">$250</span>
                <span className="text-white/75 ml-2 text-sm line-through">$399</span>
              </div>
              <p className="text-sm text-slate-200 mb-6">One payment. Yours forever.</p>
              <Link
                to={lifetimePayHref}
                className="inline-flex w-full items-center justify-center px-5 py-3 rounded-xl bg-white text-black font-semibold hover:bg-purple-50 transition-all shadow-[0_0_24px_rgba(255,255,255,0.15)] active:scale-[0.98]"
              >
                Get lifetime
              </Link>
              <ul className="mt-6 space-y-2.5 text-sm text-slate-200">
                {[
                  'Everything in Yearly',
                  'No renewals, ever',
                  'Priority support',
                  'Early access to new bundles',
                ].map((t) => (
                  <li key={t} className="flex items-center gap-2.5">
                    <Check className="h-4 w-4 text-purple-300" /> {t}
                  </li>
                ))}
              </ul>
            </div>
          </div>

        </div>
      </section>

      {/* CTA band */}
      <section className="relative py-24 border-t border-white/5">
        <div className="max-w-4xl mx-auto px-5 sm:px-8 text-center">
          <h2 className="!text-white text-3xl sm:text-5xl font-bold tracking-tight leading-[1.1] mb-5">
            Ready to ship{' '}
            <span
              className="italic text-purple-300"
              style={{ fontFamily: "'Playfair Display', Georgia, serif" }}
            >
              real growth?
            </span>
          </h2>
          <p className="text-slate-200 max-w-xl mx-auto mb-8">
            Skip the panel templates. Run growth like software.
          </p>
          <Link
            to="/auth"
            className="inline-flex items-center justify-center gap-2 px-7 py-3.5 bg-white text-black font-semibold rounded-xl hover:bg-purple-50 transition-all shadow-[0_0_24px_rgba(255,255,255,0.15)] active:scale-[0.98]"
          >
            Launch Dashboard <ArrowRight className="h-4 w-4" />
          </Link>
        </div>
      </section>
      </main>

      {/* Footer */}
      <footer className="border-t border-white/5 py-10">
        <div className="max-w-6xl mx-auto px-5 sm:px-8 flex flex-col sm:flex-row items-center justify-between gap-4 text-sm text-white/75">
          <div className="flex items-center gap-2.5">
            <img src={logo} alt="Extips Panel Pro" className="h-6 w-6 rounded object-cover ring-1 ring-white/10" />
            <span>© {new Date().getFullYear()} Extips Panel Pro. All rights reserved.</span>
          </div>
          <div className="flex items-center gap-6">
            <Link to="/legal/terms" className="hover:text-white/70">Terms</Link>
            <Link to="/legal/privacy" className="hover:text-white/70">Privacy</Link>
            <Link to="/support" className="hover:text-white/70">Support</Link>
          </div>
        </div>
      </footer>
    </div>
  );
};

export default Index;
