import { createClient } from 'npm:@supabase/supabase-js@2'
import { corsHeaders } from 'npm:@supabase/supabase-js@2/cors'

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
})

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  const auth = req.headers.get('Authorization') ?? ''
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : ''
  if (!url || !serviceKey || !token) return json({ error: 'Unauthorized' }, 401)
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } })
  if (token !== serviceKey) {
    const { data: { user }, error } = await admin.auth.getUser(token)
    if (error || !user) return json({ error: 'Unauthorized' }, 401)
    const { data: role } = await admin.from('user_roles').select('role')
      .eq('user_id', user.id).eq('role', 'admin').maybeSingle()
    if (!role) return json({ error: 'Forbidden' }, 403)
  }
  const before = await admin.from('organic_run_schedule').select('*', { count: 'exact', head: true })
    .in('status', ['pending', 'failed']).is('provider_order_id', null)
  if (before.error) return json({ error: before.error.message }, 500)
  const now = new Date().toISOString()
  const { data: rows, error } = await admin.from('organic_run_schedule').update({
    status: 'pending', scheduled_at: now, started_at: null, completed_at: null,
    provider_account_id: null, provider_account_name: null, provider_status: null,
    error_message: '[Admin retry] queued for provider dispatch', last_status_check: now,
  }).in('status', ['pending', 'failed']).is('provider_order_id', null)
    .not('error_message', 'ilike', '%[Dispatch uncertain]%').select('id')
  if (error) return json({ error: error.message }, 500)
  const response = await fetch(`${url}/functions/v1/execute-all-runs`, {
    method: 'POST', headers: { Authorization: `Bearer ${serviceKey}`, apikey: serviceKey, 'Content-Type': 'application/json' },
    body: JSON.stringify({ instant: true }),
  })
  const text = await response.text()
  let dispatch: unknown = text
  try { dispatch = JSON.parse(text) } catch { /* keep raw body */ }
  const after = await admin.from('organic_run_schedule').select('*', { count: 'exact', head: true })
    .in('status', ['pending', 'failed']).is('provider_order_id', null)
  return json({ success: response.ok, before: before.count ?? 0, queued: rows?.length ?? 0,
    after: after.count ?? 0, dispatch_http_status: response.status, dispatch }, response.ok ? 200 : 502)
})