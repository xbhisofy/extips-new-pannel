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
  let body: { run_id?: string } = {}
  try { body = await req.json() } catch { /* an empty body means retry all safe candidates */ }
  const runId = typeof body.run_id === 'string' && body.run_id.length > 0 ? body.run_id : null
  let beforeQuery = admin.from('organic_run_schedule').select('*', { count: 'exact', head: true })
    .in('status', ['pending', 'failed']).is('provider_order_id', null)
  if (runId) beforeQuery = beforeQuery.eq('id', runId)
  const before = await beforeQuery
  if (before.error) return json({ error: before.error.message }, 500)
  let candidateQuery = admin.from('organic_run_schedule').select('id,error_message')
    .in('status', ['pending', 'failed']).is('provider_order_id', null)
  if (runId) candidateQuery = candidateQuery.eq('id', runId)
  const candidates = await candidateQuery.limit(runId ? 1 : 1000)
  if (candidates.error) return json({ error: candidates.error.message }, 500)
  const retryIds = (candidates.data ?? []).filter((row) => {
    const message = (row.error_message ?? '').toLowerCase()
    return !message.includes('[dispatch uncertain]') && !message.includes('[awaiting provider confirmation]')
  }).map((row) => row.id)
  const now = new Date().toISOString()
  const update = retryIds.length > 0 ? await admin.from('organic_run_schedule').update({
    status: 'pending', scheduled_at: now, started_at: null, completed_at: null,
    provider_account_id: null, provider_account_name: null, provider_status: null,
    error_message: '[Admin retry] queued for provider dispatch', last_status_check: now,
  }).in('id', retryIds).in('status', ['pending', 'failed']).is('provider_order_id', null).select('id')
    : { data: [], error: null }
  const { data: rows, error } = update
  if (error) return json({ error: error.message }, 500)
  // Prefer the internal gateway on self-hosted installations. Besides avoiding
  // an unnecessary public round-trip, this prevents proxy request-line limits
  // from surfacing as an opaque "URI too long" admin-retry error.
  const internalBase = Deno.env.get('INTERNAL_FUNCTIONS_URL') ||
    (url.includes('kong') ? url : 'http://kong:8000')
  let response: Response
  try {
    response = await fetch(`${internalBase.replace(/\/$/, '')}/functions/v1/execute-all-runs`, {
      method: 'POST', headers: { Authorization: `Bearer ${serviceKey}`, apikey: serviceKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ instant: true }),
    })
  } catch {
    response = await fetch(`${url.replace(/\/$/, '')}/functions/v1/execute-all-runs`, {
    method: 'POST', headers: { Authorization: `Bearer ${serviceKey}`, apikey: serviceKey, 'Content-Type': 'application/json' },
    body: JSON.stringify({ instant: true }),
    })
  }
  const text = await response.text()
  let dispatch: unknown = text
  try { dispatch = JSON.parse(text) } catch { /* keep raw body */ }
  let afterQuery = admin.from('organic_run_schedule').select('*', { count: 'exact', head: true })
    .in('status', ['pending', 'failed']).is('provider_order_id', null)
  if (runId) afterQuery = afterQuery.eq('id', runId)
  const after = await afterQuery
  return json({ success: response.ok, before: before.count ?? 0, queued: rows?.length ?? 0,
    after: after.count ?? 0, run_id: runId, dispatch_http_status: response.status, dispatch }, response.ok ? 200 : 502)
})