-- Chatwoot bridge Phase 2 database tests. Run on a database that has the biz schema installed
-- (stand-in Supabase pieces first, then supabase/eab-qa-test/…_biz_schema.sql). Checks the functions in schema biz,
-- called the way the Data API calls them with the service role ("Content-Profile: biz").
\set ON_ERROR_STOP 1
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000d1', 'owner@x.com', now()), ('00000000-0000-0000-0000-0000000000d2', 'other@x.com', now());
set search_path = biz, public, extensions;
do $$
declare tid uuid; tid2 uuid; pid uuid; v1 uuid; v2 uuid; oid uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000d1', false);
  tid := create_tenant('Kopi Corner', 'cafe', 'MY');
  tid2 := create_tenant('Other Shop', 'retail', 'MY');
  perform crm_settings(tid);                                   -- makes the lead form key
  select id into oid from outlets where tenant_id = tid;
  insert into products (tenant_id, name, description) values (tid, 'Kopi O Gao', 'Strong black coffee') returning id into pid;
  insert into product_variants (tenant_id, product_id, sku, name, price, cost, track_stock) values (tid, pid, 'KOG-1', 'Hot', 3.50, 1.10, true) returning id into v1;
  insert into product_variants (tenant_id, product_id, sku, name, price, cost, track_stock) values (tid, pid, 'KOG-2', 'Iced', 4.00, 1.30, true) returning id into v2;
  insert into stock_levels (tenant_id, outlet_id, variant_id, qty) values (tid, oid, v1, 12), (tid, oid, v2, 0);
  insert into products (tenant_id, name) values (tid, 'Kopi Retired');
  update products set active = false where name = 'Kopi Retired';
  insert into products (tenant_id, name) values (tid2, 'Kopi Secret Other Shop');
  insert into chatwoot_accounts (account_id, tenant_id) values (1, tid);
  perform set_config('t.tid', tid::text, false);
end $$;

-- nobody but the service role can touch these
do $$ declare r text; ok boolean;
begin
  foreach r in array array['anon', 'authenticated'] loop
    execute format('set local role %I', r);
    begin perform chatwoot_claim_event('x'); ok := true; exception when insufficient_privilege then ok := false; end;
    assert not ok, r || ' could call chatwoot_claim_event';
    begin perform chatwoot_find_products(1, 'kopi'); ok := true; exception when insufficient_privilege then ok := false; end;
    assert not ok, r || ' could call chatwoot_find_products';
    begin perform 1 from chatwoot_events; ok := true; exception when insufficient_privilege then ok := false; end;
    assert not ok, r || ' could read chatwoot_events';
    reset role;
  end loop;
  raise notice 'CHATWOOT LOCKED TO SERVICE ROLE OK';
end $$;

set role service_role;
do $$ declare r text; j jsonb;
begin
  -- duplicate guard
  assert chatwoot_claim_event('d1') = 'new', 'first is new';
  assert chatwoot_claim_event('d1') = 'duplicate', 'second while processing is duplicate';
  perform chatwoot_finish_event('d1', true);
  assert chatwoot_claim_event('d1') = 'duplicate', 'done stays duplicate';
  assert chatwoot_claim_event('d2') = 'new', 'd2 new';
  perform chatwoot_finish_event('d2', false);
  assert chatwoot_claim_event('d2') = 'retry', 'failed can be retried';
  perform chatwoot_finish_event('d2', false);
  update chatwoot_events set attempts = 5 where key = 'd2';
  assert chatwoot_claim_event('d2') = 'duplicate', 'stops after 5 tries';
  assert chatwoot_claim_event('d3') = 'new', 'd3 new';
  update chatwoot_events set updated_at = now() - interval '3 minutes' where key = 'd3';
  assert chatwoot_claim_event('d3') = 'retry', 'stale processing is taken over';
  begin perform chatwoot_claim_event(''); assert false, 'empty key accepted'; exception when raise_exception then null; end;
  raise notice 'CHATWOOT DUPLICATE GUARD OK';

  -- products: right shop only, active only, price + in-stock only
  j := chatwoot_find_products(1, 'Do you have kopi o?');
  assert jsonb_array_length(j) = 1, 'one product: ' || j::text;
  assert j->0->>'name' = 'Kopi O Gao', 'name';
  assert (j->0->'variants'->0->>'in_stock')::boolean = true and (j->0->'variants'->1->>'in_stock')::boolean = false, 'stock flags: ' || j::text;
  assert (j->0->'variants'->0->>'price')::numeric = 3.5 and j->0->>'currency' is not null, 'price/currency';
  assert j::text !~* 'cost|qty|1\.10|"12"', 'no cost or stock count leaks: ' || j::text;
  assert chatwoot_find_products(1, 'secret other shop') = '[]'::jsonb, 'other tenant hidden';
  assert chatwoot_find_products(1, 'retired') = '[]'::jsonb, 'inactive hidden';
  assert chatwoot_find_products(99, 'kopi') = '[]'::jsonb, 'unlinked account empty';
  assert chatwoot_find_products(1, '% _ \') = '[]'::jsonb, 'wildcard-only input matches nothing';
  assert chatwoot_find_products(1, 'a b') = '[]'::jsonb, 'short words ignored';
  raise notice 'CHATWOOT PRODUCT LOOKUP OK';

  -- leads: one per conversation, needs contact details, reuses capture_lead rules
  assert (chatwoot_save_lead(1, 55, jsonb_build_object('name', 'Aisha', 'message', 'hi')))->>'reason' = 'no_contact_details', 'needs phone or email';
  assert (chatwoot_save_lead(99, 55, jsonb_build_object('name', 'Aisha', 'phone', '+60123456789')))->>'reason' = 'account_not_linked', 'unlinked';
  j := chatwoot_save_lead(1, 55, jsonb_build_object('name', 'Aisha', 'phone', '+60123456789', 'message', 'Is kopi available?', 'interest', 'Kopi O'));
  assert (j->>'saved')::boolean, 'saved: ' || j::text;
  assert (chatwoot_save_lead(1, 55, jsonb_build_object('name', 'Aisha', 'phone', '+60123456789')))->>'reason' = 'already_saved', 'only once per conversation';
  j := chatwoot_save_lead(1, 56, jsonb_build_object('name', 'Aisha', 'phone', '+60 12-345 6789', 'message', 'Another chat'));
  assert (j->>'saved')::boolean, 'second conversation saved';
end $$;
reset role;
do $$ declare t uuid := current_setting('t.tid')::uuid; n int; src text;
begin
  select count(*) into n from contacts where tenant_id = t and name = 'Aisha'; assert n = 1, 'same phone = one contact, got ' || n;
  select source into src from contacts where tenant_id = t and name = 'Aisha'; assert src = 'chatwoot', 'source ' || src;
  select count(*) into n from deals where tenant_id = t; assert n = 2, 'one deal per conversation, got ' || n;
  select count(*) into n from activities where tenant_id = t and body like '%kopi available%'; assert n = 1, 'message kept as a note';
  raise notice 'CHATWOOT LEAD SAVE OK';
end $$;
-- installing the schema file a second time changes nothing (checked by the runner)
