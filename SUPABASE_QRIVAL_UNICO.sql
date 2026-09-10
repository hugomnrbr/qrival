-- Q-Rival V52 — correções para o banco já instalado pela V51
-- Corrige:
-- 1) qr_daily_claims: recompensa diária + baú no mesmo dia geravam conflito de PK.
-- 2) Morte Súbita: não depende mais de gen_random_bytes().
-- 3) Reforça a função de criação de sala e a consulta de torneios.

begin;

-- ================================================================
-- 1. RECOMPENSA DIÁRIA / BAÚ
-- ================================================================
-- A PK antiga era (user_id, claim_date), mas o sistema possui duas
-- recompensas independentes no mesmo dia: diária e baú.
alter table if exists public.qr_daily_claims
  drop constraint if exists qr_daily_claims_pkey;

alter table if exists public.qr_daily_claims
  add primary key (user_id, claim_date, chest);

create or replace function public.qr_claim_daily_reward(p_chest boolean default false)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  today date := current_date;
  prev date;
  laststreak integer := 0;
  v_coins integer := 0;
  item text := null;
  nextstreak integer := 1;
  inserted_user uuid;
  min_coins integer := 0;
  max_coins integer := 0;
  item_chance numeric := 0;
begin
  if auth.uid() is null then
    raise exception 'Faça login.';
  end if;

  select max(claim_date), coalesce(max(streak),0)
    into prev,laststreak
  from public.qr_daily_claims
  where user_id=auth.uid() and chest=false;

  nextstreak := case
    when prev=today-1 then laststreak+1
    else 1
  end;

  select
    greatest(0,coalesce(chest_min_coins,50)),
    greatest(0,coalesce(chest_max_coins,150)),
    greatest(0,least(1,coalesce(chest_item_chance,0.08)))
  into min_coins,max_coins,item_chance
  from public.qr_mode_settings
  where id=1;

  if p_chest then
    if max_coins < min_coins then
      max_coins := min_coins;
    end if;

    v_coins := floor(random() * (max_coins-min_coins+1))::integer + min_coins;

    -- Itens raros são escolhidos somente entre produtos ativos.
    select id::text
      into item
    from public.premium_items
    where active=true
      and lower(coalesce(rarity,'')) in ('rare','epic','legendary','mythic','raro','épico','lendário','mítico')
      and random() < item_chance
    order by random()
    limit 1;
  else
    v_coins := greatest(0,coalesce((select daily_coin_base from public.qr_mode_settings where id=1),25))
               + least(nextstreak,25)*2;
  end if;

  -- Idempotência + proteção contra dois cliques simultâneos.
  insert into public.qr_daily_claims(
    user_id,claim_date,streak,reward_coins,reward_item_id,chest
  ) values(
    auth.uid(),today,nextstreak,v_coins,item,p_chest
  )
  on conflict (user_id,claim_date,chest) do nothing
  returning user_id into inserted_user;

  if inserted_user is null then
    raise exception 'Recompensa de hoje já foi resgatada.';
  end if;

  update public.profiles
     set coins=coalesce(coins,0)+v_coins
   where id=auth.uid();

  if item is not null then
    insert into public.user_premium_items(user_id,item_id,active,purchased_at)
    values(auth.uid(),item,false,now())
    on conflict do nothing;
  end if;

  return jsonb_build_object(
    'ok',true,
    'coins',v_coins,
    'item_id',item,
    'streak',nextstreak,
    'chest',p_chest
  );
end;
$$;

revoke all on function public.qr_claim_daily_reward(boolean) from public;
grant execute on function public.qr_claim_daily_reward(boolean) to authenticated;

-- ================================================================
-- 2. MORTE SÚBITA — criação de código sem pgcrypto
-- ================================================================
-- Usa MD5 + random/clock_timestamp, disponíveis no PostgreSQL padrão.
-- Assim a sala funciona mesmo quando a extensão pgcrypto não estiver ativa.
create or replace function public.qr_create_sudden_room(p_category text default 'Geral')
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  rid uuid;
  c text;
  maxp integer;
  tries integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Faça login.';
  end if;

  if not exists(
    select 1 from public.qr_mode_settings
    where id=1 and enabled=true and sudden_death_enabled=true
  ) then
    raise exception 'Modo Morte Súbita está desativado.';
  end if;

  select least(8,greatest(2,coalesce(sudden_death_max_players,8)))
    into maxp
  from public.qr_mode_settings
  where id=1;

  if maxp is null then maxp := 8; end if;

  loop
    tries := tries + 1;
    c := upper(substr(md5(random()::text || clock_timestamp()::text || auth.uid()::text),1,6));
    exit when not exists(select 1 from public.qr_sudden_rooms where code=c);
    if tries > 20 then
      raise exception 'Não foi possível gerar o código da sala. Tente novamente.';
    end if;
  end loop;

  insert into public.qr_sudden_rooms(code,host_id,category,max_players)
  values(c,auth.uid(),coalesce(nullif(trim(p_category),''),'Geral'),maxp)
  returning id into rid;

  insert into public.qr_sudden_players(room_id,user_id)
  values(rid,auth.uid())
  on conflict do nothing;

  return rid;
end;
$$;

revoke all on function public.qr_create_sudden_room(text) from public;
grant execute on function public.qr_create_sudden_room(text) to authenticated;

-- ================================================================
-- 3. TORNEIOS — consulta segura e função de entrada
-- ================================================================
-- Garante os quatro valores permitidos e limite de 18 jogadores.
update public.qr_tournaments
set max_players=least(greatest(coalesce(max_players,18),2),18),
    entry_fee=case when entry_fee in (100,200,500,1000) then entry_fee else 100 end;

-- ================================================================
-- 4. PGCRYPTO: pode existir no Supabase, mas não é mais requisito
-- para criar salas. Se o projeto permitir a extensão, ela fica ativa
-- para as demais funções que usam gen_random_uuid().
-- ================================================================
create extension if not exists pgcrypto;

commit;



-- ================================================================
-- Q-RIVAL V56 — CORREÇÕES FINAIS CONSOLIDADAS
-- ================================================================
-- Este é o único SQL desta versão. Não é necessário executar os SQL
-- históricos que estavam no ZIP.
--
-- Inclui:
--  • nível global 1–1000 com 100 XP por nível;
--  • partidas contra Bot dão XP, mas NÃO alteram vitórias/derrotas;
--  • VIP mensal (30 dias) com validade no banco;
--  • preço do VIP continua editável pelo painel administrativo;
--  • inventário/reação de partida com RLS + Realtime;
--  • eventos com objetivo + notificações para todos os jogadores;
--  • limpeza de categorias quebradas da Loja;
--  • limite/estrutura segura de torneios.

begin;

-- ---------------------------------------------------------------
-- 1) VIP MENSAL
-- ---------------------------------------------------------------
alter table if exists public.profiles
  add column if not exists premium_vip_until timestamptz;

alter table if exists public.user_premium_items
  add column if not exists expires_at timestamptz;

-- Converte VIPs antigos permanentes em uma primeira janela de 30 dias.
update public.profiles
set premium_vip_until=coalesce(premium_vip_until,now()+interval '30 days')
where coalesce(premium_vip,false)=true;

update public.premium_items
set name='Q-Rival VIP Mensal',
    description='VIP por 30 dias: +25% de XP nas vitórias, identificação VIP e benefícios exclusivos.',
    kind='vip',
    category='VIP'
where kind='vip' or id='qrvip-permanente';

-- Compra: VIP e Passe possuem validade de 30 dias.
drop function if exists public.purchase_premium_item(text,bigint);
create function public.purchase_premium_item(p_item_id text,p_expected_price bigint default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  it public.premium_items;
  charge bigint;
  bal bigint;
  promo_ok boolean;
  already boolean;
  category_on boolean:=true;
  expires timestamptz;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;

  select * into it
  from public.premium_items
  where id::text=trim(p_item_id) and active=true
  limit 1;
  if it.id is null then raise exception 'Item não encontrado ou indisponível'; end if;

  if it.category='VIP' then
    category_on:=coalesce((select vip_enabled from public.premium_store_settings where id=1),true);
  elsif it.category='Moedas' then
    category_on:=coalesce((select coins_enabled and payments_enabled from public.premium_store_settings where id=1),false);
  elsif it.category='Passe' then
    category_on:=coalesce((select pass_enabled from public.premium_store_settings where id=1),true);
  else
    category_on:=coalesce((select cosmetics_enabled from public.premium_store_settings where id=1),true);
  end if;

  if not coalesce((select enabled from public.premium_store_settings where id=1),true)
     or not category_on then
    raise exception 'As compras desta categoria estão desativadas';
  end if;

  promo_ok:=coalesce(it.promo_active,false)
    and coalesce(it.promo_price_coins,0)>0
    and coalesce(it.promo_price_coins,0)<coalesce(it.price_coins,0)
    and (it.promo_expires_at is null or it.promo_expires_at>now());

  charge:=case when promo_ok then it.promo_price_coins else coalesce(it.price_coins,it.price_cents,0) end;
  if charge is null or charge<0 then raise exception 'Preço do item inválido'; end if;
  if p_expected_price is not null and p_expected_price<>charge then
    raise exception 'O preço do item mudou. Atualize a loja e tente novamente.';
  end if;

  select exists(
    select 1 from public.user_premium_items
    where user_id=auth.uid()
      and item_id=it.id
      and (expires_at is null or expires_at>now())
  ) into already;

  if not already then
    update public.profiles
    set coins=coalesce(coins,0)-charge
    where id=auth.uid() and coalesce(coins,0)>=charge
    returning coins into bal;
    if bal is null then raise exception 'Você não possui QuizCoins suficientes'; end if;

    expires:=case when it.kind in ('vip','pass') then now()+interval '30 days' else null end;

    if exists(select 1 from public.user_premium_items where user_id=auth.uid() and item_id=it.id) then
      update public.user_premium_items
      set purchased_at=now(),expires_at=expires,active=false
      where user_id=auth.uid() and item_id=it.id;
    else
      insert into public.user_premium_items(user_id,item_id,active,purchased_at,expires_at)
      values(auth.uid(),it.id,false,now(),expires);
    end if;

    insert into public.coin_ledger(user_id,amount,source_type,source_id,description)
    values(auth.uid(),-charge,'premium_purchase',gen_random_uuid()::text,'Compra: '||coalesce(it.name,'Item'));

    if it.kind='pass' then
      update public.profiles set premium_pass_until=expires where id=auth.uid();
    elsif it.kind='vip' then
      update public.profiles set premium_vip=true,premium_vip_until=expires where id=auth.uid();
    end if;
  else
    select coins into bal from public.profiles where id=auth.uid();
  end if;

  return jsonb_build_object(
    'ok',true,
    'already_owned',already,
    'balance',coalesce(bal,0),
    'charge',case when already then 0 else charge end,
    'item_id',it.id,
    'kind',it.kind,
    'expires_at',case when it.kind in ('vip','pass') then coalesce(expires,(select expires_at from public.user_premium_items where user_id=auth.uid() and item_id=it.id)) else null end
  );
end;
$$;
revoke all on function public.purchase_premium_item(text,bigint) from public;
grant execute on function public.purchase_premium_item(text,bigint) to authenticated;

-- Ativação também respeita a validade mensal do VIP.
drop function if exists public.activate_premium_item(text);
create function public.activate_premium_item(p_item_id text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  it public.premium_items;
  bal bigint;
  title_uuid uuid;
  expires timestamptz;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  select * into it from public.premium_items where id::text=trim(p_item_id) limit 1;
  if it.id is null then raise exception 'Item não encontrado'; end if;

  select expires_at into expires
  from public.user_premium_items
  where user_id=auth.uid() and item_id=it.id
    and (expires_at is null or expires_at>now());

  if not exists(
    select 1 from public.user_premium_items
    where user_id=auth.uid() and item_id=it.id
      and (expires_at is null or expires_at>now())
  ) then raise exception 'Você ainda não possui este item ativo'; end if;

  update public.user_premium_items up
  set active=false
  where up.user_id=auth.uid()
    and exists(select 1 from public.premium_items x where x.id=up.item_id and x.kind=it.kind);
  update public.user_premium_items set active=true where user_id=auth.uid() and item_id=it.id;

  if it.kind='vip' then
    update public.profiles set premium_vip=true,premium_vip_until=expires where id=auth.uid();
  elsif it.kind='pass' then
    update public.profiles set premium_pass_until=expires where id=auth.uid();
  elsif it.kind='frame' then
    update public.profiles set premium_frame=it.id::text where id=auth.uid();
  elsif it.kind='avatar' then
    update public.profiles set premium_avatar=it.id::text where id=auth.uid();
  elsif it.kind='effect' then
    update public.profiles set premium_effect=it.id::text where id=auth.uid();
  elsif it.kind='theme' then
    update public.profiles set premium_theme=it.id::text where id=auth.uid();
  elsif it.kind='background' then
    update public.profiles set premium_background=it.id::text where id=auth.uid();
  elsif it.kind='badge' then
    update public.profiles set premium_badge=it.id::text where id=auth.uid();
  elsif it.kind='title' then
    if coalesce(it.source_type,'')='title' and coalesce(it.source_id,'')<>'' then
      begin title_uuid:=it.source_id::uuid; exception when others then title_uuid:=null; end;
    end if;
    if title_uuid is null then
      select id into title_uuid from public.titles where lower(trim(name))=lower(trim(it.name)) and active=true limit 1;
    end if;
    if title_uuid is not null then
      update public.user_titles set is_main=false where user_id=auth.uid();
      insert into public.user_titles(user_id,title_id,is_main)
      values(auth.uid(),title_uuid,true)
      on conflict(user_id,title_id) do update set is_main=true;
      update public.profiles set main_title_id=title_uuid,premium_title=it.id::text where id=auth.uid();
    else
      update public.profiles set premium_title=it.id::text where id=auth.uid();
    end if;
  end if;

  select coins into bal from public.profiles where id=auth.uid();
  return jsonb_build_object('ok',true,'item_id',it.id,'kind',it.kind,'balance',coalesce(bal,0),'expires_at',expires);
end;
$$;
revoke all on function public.activate_premium_item(text) from public;
grant execute on function public.activate_premium_item(text) to authenticated;

-- ---------------------------------------------------------------
-- 2) XP: 100 XP por nível, até o nível 1000
-- ---------------------------------------------------------------
create or replace function public.quizup_balance_level_v47()
returns trigger
language plpgsql
as $$
begin
  new.xp:=greatest(0,coalesce(new.xp,0));
  new.level:=least(1000,greatest(1,1+floor(new.xp/100)::int));
  return new;
end;
$$;
drop trigger if exists quizup_balance_level_v47 on public.profiles;
create trigger quizup_balance_level_v47
before insert or update of xp on public.profiles
for each row execute function public.quizup_balance_level_v47();
update public.profiles
set level=least(1000,greatest(1,1+floor(greatest(0,coalesce(xp,0))/100)::int));

update public.qr_seasons set xp_per_level=100 where xp_per_level is null or xp_per_level=250;
create or replace function public.quizup_topic_level_v47(p_xp bigint)
returns integer
language sql
stable
as $$
  select least(1000,greatest(1,1+floor(greatest(0,coalesce(p_xp,0))/100)::int));
$$;
revoke all on function public.quizup_topic_level_v47(bigint) from public;
grant execute on function public.quizup_topic_level_v47(bigint) to authenticated;

-- Partida contra Bot: adiciona XP sem registrar vitória/derrota.
create or replace function public.apply_bot_xp(p_xp integer,p_category text default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare new_xp bigint;
begin
  if auth.uid() is null then raise exception 'Não autenticado'; end if;
  update public.profiles
  set xp=coalesce(xp,0)+greatest(0,coalesce(p_xp,0))
  where id=auth.uid()
  returning xp into new_xp;
  return jsonb_build_object('ok',true,'xp',coalesce(new_xp,0),'category',p_category);
end;
$$;
revoke all on function public.apply_bot_xp(integer,text) from public;
grant execute on function public.apply_bot_xp(integer,text) to authenticated;

-- ---------------------------------------------------------------
-- 3) INVENTÁRIO
-- ---------------------------------------------------------------
alter table if exists public.user_premium_items enable row level security;
drop policy if exists "user premium items own read" on public.user_premium_items;
create policy "user premium items own read" on public.user_premium_items
for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists "user premium items own update" on public.user_premium_items;
create policy "user premium items own update" on public.user_premium_items
for update to authenticated using(user_id=auth.uid() or public.is_admin()) with check(user_id=auth.uid() or public.is_admin());

-- ---------------------------------------------------------------
-- 4) EVENTOS + NOTIFICAÇÃO PARA TODO O SERVIDOR
-- ---------------------------------------------------------------
create table if not exists public.qr_events(
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  icon text default '🔥',
  event_type text not null default 'weekly',
  category text,
  start_at timestamptz not null,
  end_at timestamptz not null,
  active boolean not null default true,
  xp_multiplier numeric(6,2) not null default 1,
  coin_reward integer not null default 0,
  reward_item_id text,
  rules jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint qr_events_dates check(end_at>start_at),
  constraint qr_events_type check(event_type in ('weekly','category','special'))
);
alter table public.qr_events add column if not exists rules jsonb not null default '{}'::jsonb;
alter table public.qr_events enable row level security;
drop policy if exists "qr_events_public_select" on public.qr_events;
create policy "qr_events_public_select" on public.qr_events for select to authenticated
using(active=true or public.is_admin());
drop policy if exists "qr_events_admin_write" on public.qr_events;
create policy "qr_events_admin_write" on public.qr_events for all to authenticated
using(public.is_admin()) with check(public.is_admin());

create table if not exists public.notifications(
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  type text not null,
  title text not null,
  body text,
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.notifications enable row level security;
-- Compatibilidade com bancos v anteriores: permitir todos os tipos de notificação usados pelo Q-Rival.
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
check (type in ('system','challenge','friend_request','message','like','comment','achievement','coin','event'));


drop policy if exists "notifications own read" on public.notifications;
create policy "notifications own read" on public.notifications for select to authenticated using(recipient_id=auth.uid());
drop policy if exists "notifications own update" on public.notifications;
create policy "notifications own update" on public.notifications for update to authenticated using(recipient_id=auth.uid()) with check(recipient_id=auth.uid());
do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime')
     and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='notifications') then
    execute 'alter publication supabase_realtime add table public.notifications';
  end if;
exception when others then null; end $$;

create or replace function public.notify_new_qr_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  goal text:=coalesce(new.rules->>'goal',new.rules->>'objective','');
  body_text text;
begin
  body_text:='Começa em '||to_char(new.start_at at time zone 'America/Sao_Paulo','DD/MM/YYYY HH24:MI')||'. '||
             'Termina em '||to_char(new.end_at at time zone 'America/Sao_Paulo','DD/MM/YYYY HH24:MI')||'.';
  if goal<>'' then body_text:=body_text||' O que fazer: '||goal; end if;
  insert into public.notifications(recipient_id,actor_id,type,title,body,data)
  select p.id,new.created_by,'event','🔥 Novo evento: '||new.name,body_text,
         jsonb_build_object('event_id',new.id,'start_at',new.start_at,'end_at',new.end_at)
  from public.profiles p
  where not exists(
    select 1 from public.notifications n
    where n.recipient_id=p.id and n.type='event'
      and n.data->>'event_id'=new.id::text
  );
  return new;
end;
$$;
drop trigger if exists trg_notify_new_qr_event on public.qr_events;
create trigger trg_notify_new_qr_event
after insert on public.qr_events
for each row execute function public.notify_new_qr_event();

-- ---------------------------------------------------------------
-- 5) LIMPEZA DAS CATEGORIAS QUE GERAVAM "undefined" NA LOJA
-- ---------------------------------------------------------------
update public.store_categories
set active=false
where lower(trim(coalesce(name,''))) like '%undefined%'
   or lower(trim(coalesce(name,''))) in ('mídias','midias','passe');

-- ---------------------------------------------------------------
-- 6) TORNEIOS: limites seguros. O erro ERR_INSUFFICIENT_RESOURCES
-- também era provocado por chamadas repetidas no front-end; o app v56
-- remove o loop de requisições e este bloco mantém os dados válidos.
-- ---------------------------------------------------------------
update public.qr_tournaments
set max_players=least(greatest(coalesce(max_players,18),2),18),
    entry_fee=case when entry_fee in (100,200,500,1000) then entry_fee else 100 end;

alter table public.qr_tournaments drop constraint if exists qr_tournaments_max;
alter table public.qr_tournaments add constraint qr_tournaments_max check(max_players between 2 and 18);

-- Realtime das notificações/eventos quando a publicação estiver disponível.
do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='qr_events') then
      execute 'alter publication supabase_realtime add table public.qr_events';
    end if;
  end if;
exception when others then null; end $$;

commit;
