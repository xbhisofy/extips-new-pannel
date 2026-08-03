import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { toast } from "sonner";
import { Copy, RefreshCw, Send, ShieldCheck, ArrowLeft } from "lucide-react";
import { Link } from "react-router-dom";

import { useAuth } from "@/hooks/useAuth";

export default function TelegramBot() {
  const { user } = useAuth();
  const [code, setCode] = useState<string | null>(null);
  const [expires, setExpires] = useState<string | null>(null);
  const [linked, setLinked] = useState<{ username: string | null; chat_id: number | null } | null>(null);
  const [botUsername, setBotUsername] = useState<string>("YourBot");
  const [loading, setLoading] = useState(false);
  const [isAdmin, setIsAdmin] = useState(false);

  const loadStatus = async () => {
    if (!user) return;
    const { data } = await supabase
      .from("telegram_engagement_links")
      .select("link_code, code_expires_at, telegram_username, telegram_chat_id, status")
      .eq("user_id", user.id)
      .maybeSingle();
    if (data) {
      setCode(data.link_code);
      setExpires(data.code_expires_at);
      if (data.status === "linked") setLinked({ username: data.telegram_username, chat_id: data.telegram_chat_id });
      else setLinked(null);
    }
    const { data: role } = await supabase.from("user_roles").select("role").eq("user_id", user.id).eq("role", "admin").maybeSingle();
    setIsAdmin(!!role);
  };

  useEffect(() => {
    loadStatus();
    // Bot username is a public env; fall back to the token secret name hint.
    const envUser = (import.meta.env.VITE_TELEGRAM_BOT_USERNAME as string | undefined) ?? "Extips PanelPro_Bot";
    setBotUsername(envUser);
  }, [user?.id]);

  const generate = async () => {
    setLoading(true);
    const { data, error } = await supabase.rpc("generate_telegram_link_code");
    setLoading(false);
    if (error) return toast.error(error.message);
    setCode((data as any)?.code);
    setExpires((data as any)?.expires_at);
    toast.success("Code generated. Valid for 30 minutes.");
  };

  const copy = (t: string) => {
    navigator.clipboard.writeText(t);
    toast.success("Copied");
  };

  const setupWebhook = async () => {
    const { data, error } = await supabase.functions.invoke("telegram-set-webhook");
    if (error) return toast.error(error.message);
    console.log("webhook", data);
    toast.success("Webhook registered");
  };

  const startCommand = code ? `/link ${code}` : "/link YOURCODE";

  return (
    <div className="mx-auto max-w-2xl p-4 space-y-4 pb-24">
      <div className="flex items-center justify-between gap-2">
        <div>
          <h1 className="text-2xl font-bold">Telegram Bot</h1>
          <p className="text-muted-foreground text-sm">Manage orders & posts from Telegram.</p>
        </div>
        <Button asChild variant="outline" size="sm">
          <Link to="/dashboard"><ArrowLeft className="w-4 h-4 mr-1" /> Home</Link>
        </Button>
      </div>


      <Card>
        <CardHeader><CardTitle className="flex items-center gap-2"><Send className="w-4 h-4" /> Pair your chat</CardTitle></CardHeader>
        <CardContent className="space-y-3">
          {linked ? (
            <div className="rounded-lg border border-green-500/40 bg-green-500/10 p-3 text-sm">
              ✅ Linked as <b>@{linked.username || "unknown"}</b> (chat {linked.chat_id})
            </div>
          ) : (
            <div className="text-sm text-muted-foreground">Not linked yet.</div>
          )}

          <div className="flex gap-2">
            <Button onClick={generate} disabled={loading} size="sm">
              <RefreshCw className="w-4 h-4 mr-1" /> {code ? "Regenerate code" : "Generate code"}
            </Button>
            {code && (
              <Button variant="outline" size="sm" onClick={() => copy(code)}>
                <Copy className="w-4 h-4 mr-1" /> {code}
              </Button>
            )}
          </div>
          {expires && <div className="text-xs text-muted-foreground">Expires: {new Date(expires).toLocaleString()}</div>}

          <ol className="text-sm space-y-2 list-decimal pl-5">
            <li>
              Open bot:{" "}
              <a className="text-primary underline" href={`https://t.me/${botUsername}`} target="_blank" rel="noreferrer">
                @{botUsername}
              </a>
            </li>
            <li>Send <code className="px-1 rounded bg-muted">/start</code></li>
            <li>Send <code className="px-1 rounded bg-muted">{startCommand}</code>
              {code && (
                <Button variant="ghost" size="sm" className="ml-2 h-6" onClick={() => copy(startCommand)}>
                  <Copy className="w-3 h-3" />
                </Button>
              )}
            </li>
          </ol>
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle>Available commands</CardTitle></CardHeader>
        <CardContent className="text-sm space-y-1 font-mono">
          <div>/wallet — balance</div>
          <div>/posts — recent Instagram posts (inline Boost buttons)</div>
          <div>/orders — recent engagement orders</div>
          <div>/order &lt;instagram-link&gt; [views] [likes] [comments] — place order</div>
          <div>/setdefault VIEWS LIKES COMMENTS [DRIP_MIN] — set preset</div>
          <div>/mode auto|manual — auto-order on new posts</div>
          <div>/cancel ORDER_ID — cancel pending order</div>
          <div>/help — show commands</div>
        </CardContent>

      </Card>

      {isAdmin && (
        <Card>
          <CardHeader><CardTitle className="flex items-center gap-2"><ShieldCheck className="w-4 h-4" /> Admin</CardTitle></CardHeader>
          <CardContent>
            <Button onClick={setupWebhook} size="sm" variant="outline">Register Telegram webhook</Button>
            <p className="text-xs text-muted-foreground mt-2">One-time setup so Telegram forwards messages to our backend.</p>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
